from __future__ import annotations

import argparse
import ipaddress
import json
import os
import queue
import signal
import socket
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

from sonos_redirector.discovery import (
    discover_sonos_locations,
    parse_av_transport_control_url,
    parse_friendly_name,
    parse_ip_from_location,
)
from sonos_redirector.soap import (
    build_didl_metadata,
    build_get_media_info_envelope,
    build_play_envelope,
    build_set_av_transport_uri_envelope,
    build_stop_envelope,
    parse_current_transport_uri,
)


class AudioQueue:
    def __init__(self, max_chunks: int = 128) -> None:
        self._chunks: queue.Queue[bytes] = queue.Queue(maxsize=max_chunks)

    def put(self, chunk: bytes) -> None:
        if self._chunks.full():
            self._chunks.get_nowait()
        self._chunks.put_nowait(chunk)

    def get(self, timeout: float = 1.0) -> bytes:
        return self._chunks.get(timeout=timeout)


class StreamHandler(BaseHTTPRequestHandler):
    audio_queue: AudioQueue
    stream_path = "/stream"
    channels = 2
    sample_rate = 48000
    sample_width = 2

    def do_GET(self) -> None:  # noqa: N802
        if self.path != self.stream_path:
            self.send_error(404, "Not found")
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(self._wav_header())
        while True:
            try:
                self.wfile.write(self.audio_queue.get())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, queue.Empty):
                break

    def log_message(self, format: str, *args) -> None:
        return

    def _wav_header(self) -> bytes:
        import io

        fake_file = io.BytesIO()
        with wave.open(fake_file, "wb") as wav:
            wav.setnchannels(self.channels)
            wav.setsampwidth(self.sample_width)
            wav.setframerate(self.sample_rate)
            wav.writeframes(b"")
        return fake_file.getvalue()


def is_retryable_soap_error(error: Exception) -> bool:
    if isinstance(error, HTTPError):
        return error.code >= 500 or error.code == 429
    return isinstance(error, (URLError, TimeoutError, ConnectionResetError, socket.timeout))


def send_soap(
    endpoint: str,
    action: str,
    payload: str,
    *,
    timeout_s: float = 6.0,
    retries: int = 2,
    retry_delay_s: float = 0.35,
    expect_response: bool = False,
) -> str | None:
    max_attempts = max(1, int(retries) + 1)
    retry_delay_s = max(0.0, retry_delay_s)
    last_error: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        req = Request(
            endpoint,
            method="POST",
            data=payload.encode("utf-8"),
            headers={
                "Content-Type": 'text/xml; charset="utf-8"',
                "SOAPACTION": f'"urn:schemas-upnp-org:service:AVTransport:1#{action}"',
            },
        )

        try:
            with urlopen(req, timeout=timeout_s) as response:
                if expect_response:
                    return response.read().decode("utf-8", errors="ignore")
                return None
        except Exception as exc:
            last_error = exc
            should_retry = attempt < max_attempts and is_retryable_soap_error(exc)
            if not should_retry:
                break
            time.sleep(retry_delay_s * attempt)

    raise RuntimeError(
        f"Sonos SOAP action '{action}' failed for endpoint {endpoint} "
        f"after {max_attempts} attempt(s): {last_error}"
    ) from last_error


def fetch_av_transport_endpoint(speaker_ip: str) -> str:
    desc_url = f"http://{speaker_ip}:1400/xml/device_description.xml"
    with urlopen(desc_url, timeout=6) as response:
        xml = response.read().decode("utf-8")
    control_path = parse_av_transport_control_url(xml)
    if not control_path:
        raise RuntimeError("Could not find AVTransport control URL in Sonos device description")
    return urljoin(desc_url, control_path)


def fetch_current_transport_source(
    endpoint: str,
    *,
    timeout_s: float = 6.0,
    retries: int = 2,
    retry_delay_s: float = 0.35,
) -> tuple[str, str]:
    response_xml = send_soap(
        endpoint,
        "GetMediaInfo",
        build_get_media_info_envelope(),
        timeout_s=timeout_s,
        retries=retries,
        retry_delay_s=retry_delay_s,
        expect_response=True,
    )
    if not isinstance(response_xml, str):
        return "", ""
    return parse_current_transport_uri(response_xml)


def discover_speakers(timeout_s: float) -> list[dict[str, str]]:
    speakers: list[dict[str, str]] = []
    for location in discover_sonos_locations(timeout_s=timeout_s):
        try:
            with urlopen(location, timeout=4) as response:
                xml = response.read().decode("utf-8", errors="ignore")
            friendly_name = parse_friendly_name(xml) or "Sonos speaker"
            ip = parse_ip_from_location(location) or ""
            speakers.append(
                {
                    "name": friendly_name,
                    "ip": ip,
                    "location": location,
                }
            )
        except Exception:
            continue

    return sorted(speakers, key=lambda s: (s.get("name", ""), s.get("ip", "")))


def is_ip_address(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def normalize_speaker_name(value: str) -> str:
    return " ".join(value.strip().lower().split())


def canonicalize_http_url(url: str) -> str:
    candidate = url.strip()
    if not candidate:
        return ""

    parsed = urlsplit(candidate)
    scheme = parsed.scheme.lower()
    hostname = (parsed.hostname or "").lower()
    if scheme not in {"http", "https"} or not hostname:
        return candidate

    default_port = 443 if scheme == "https" else 80
    port = parsed.port or default_port
    path = parsed.path or "/"

    return f"{scheme}://{hostname}:{port}{path}"


def stream_url_matches_state(*, current_uri: str, state_stream_url: str) -> bool:
    canonical_current = canonicalize_http_url(current_uri)
    canonical_state = canonicalize_http_url(state_stream_url)
    if not canonical_current or not canonical_state:
        return False
    return canonical_current == canonical_state


def format_speaker_choices(speakers: list[dict[str, str]]) -> str:
    labels = [f"{speaker.get('name', 'Sonos speaker')} ({speaker.get('ip', 'unknown')})" for speaker in speakers]
    return ", ".join(sorted(labels))


def resolve_speaker_selector(selector: str, timeout_s: float) -> dict[str, str]:
    normalized_selector = selector.strip()
    if not normalized_selector:
        raise RuntimeError("Speaker selector is empty")

    if is_ip_address(normalized_selector):
        return {
            "name": "",
            "ip": normalized_selector,
            "location": "",
        }

    speakers = discover_speakers(timeout_s=timeout_s)
    if not speakers:
        raise RuntimeError(
            "No Sonos speakers discovered on the local network while resolving speaker selector"
        )

    requested_name = normalize_speaker_name(normalized_selector)
    exact_matches = [speaker for speaker in speakers if normalize_speaker_name(speaker.get("name", "")) == requested_name]
    if len(exact_matches) == 1:
        return exact_matches[0]
    if len(exact_matches) > 1:
        raise RuntimeError(
            f"Speaker selector '{selector}' matched multiple speakers: {format_speaker_choices(exact_matches)}"
        )

    partial_matches = [speaker for speaker in speakers if requested_name in normalize_speaker_name(speaker.get("name", ""))]
    if len(partial_matches) == 1:
        return partial_matches[0]
    if len(partial_matches) > 1:
        raise RuntimeError(
            f"Speaker selector '{selector}' is ambiguous: {format_speaker_choices(partial_matches)}"
        )

    raise RuntimeError(
        f"Speaker selector '{selector}' did not match discovered speakers: {format_speaker_choices(speakers)}"
    )


def fetch_speaker_name(speaker_ip: str) -> str:
    desc_url = f"http://{speaker_ip}:1400/xml/device_description.xml"
    with urlopen(desc_url, timeout=4) as response:
        xml = response.read().decode("utf-8", errors="ignore")
    return parse_friendly_name(xml) or ""


def recover_speaker_ip_from_discovery(*, preferred_ip: str, speaker_name: str, timeout_s: float) -> str | None:
    speakers = discover_speakers(timeout_s=timeout_s)
    if preferred_ip:
        for speaker in speakers:
            if speaker.get("ip", "").strip() == preferred_ip:
                return preferred_ip

    normalized_name = normalize_speaker_name(speaker_name)
    if not normalized_name:
        return None

    matching_by_name = [speaker for speaker in speakers if normalize_speaker_name(speaker.get("name", "")) == normalized_name]
    if len(matching_by_name) != 1:
        return None

    recovered_ip = matching_by_name[0].get("ip", "").strip()
    if not recovered_ip:
        return None

    return recovered_ip


def start_loopback_capture(audio_queue: AudioQueue, samplerate: int = 48000) -> threading.Thread:
    import sounddevice as sd

    def callback(indata, frames, callback_time, status):
        del frames, callback_time
        if status:
            return
        audio_queue.put(bytes(indata))

    wasapi = sd.WasapiSettings(loopback=True)

    def run() -> None:
        with sd.RawInputStream(
            samplerate=samplerate,
            channels=2,
            dtype="int16",
            blocksize=2048,
            extra_settings=wasapi,
            callback=callback,
        ):
            threading.Event().wait()

    thread = threading.Thread(target=run, name="loopback-capture", daemon=True)
    thread.start()
    return thread


def get_local_ip_for_target(target_host: str) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((target_host, 1400))
        return sock.getsockname()[0]


def default_state_file() -> str:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        root = Path(local_app_data) / "WinToSonos"
    else:
        root = Path.home() / ".wintosonos"
    return str(root / "redirect-state.json")


def normalize_stream_path(path: str) -> str:
    if not path.startswith("/"):
        return f"/{path}"
    return path


def write_state_file(path: str, payload: dict[str, str | int]) -> None:
    state_path = Path(path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def read_state_file(path: str) -> dict[str, str | int] | None:
    state_path = Path(path)
    if not state_path.exists():
        return None
    return json.loads(state_path.read_text(encoding="utf-8"))


def remove_state_file(path: str) -> None:
    state_path = Path(path)
    if state_path.exists():
        state_path.unlink()


def install_signal_handlers(stop_event: threading.Event) -> None:
    def handler(signum, frame):
        del signum, frame
        stop_event.set()

    for sig_name in ("SIGINT", "SIGTERM"):
        sig = getattr(signal, sig_name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, handler)
        except ValueError:
            continue


def run_discover(args: argparse.Namespace) -> int:
    speakers = discover_speakers(timeout_s=args.timeout)
    if args.json:
        print(json.dumps(speakers, indent=2))
        return 0

    if not speakers:
        print("No Sonos speakers discovered")
        return 0

    for speaker in speakers:
        print(f"{speaker['name']}\t{speaker['ip']}")
    return 0


def run_start(args: argparse.Namespace) -> int:
    if args.speaker and args.speaker_ip:
        raise RuntimeError("Use either --speaker or --speaker-ip for start, not both")

    speaker_selector = (args.speaker or args.speaker_ip or "").strip()
    if not speaker_selector:
        raise RuntimeError("Provide --speaker or --speaker-ip for start")

    resolved_speaker = resolve_speaker_selector(speaker_selector, timeout_s=args.discover_timeout)
    speaker_ip = resolved_speaker.get("ip", "").strip()
    if not speaker_ip:
        raise RuntimeError(f"Could not resolve Sonos speaker from selector '{speaker_selector}'")

    speaker_name = resolved_speaker.get("name", "").strip()
    if not speaker_name:
        try:
            speaker_name = fetch_speaker_name(speaker_ip)
        except Exception:
            speaker_name = ""

    stream_path = normalize_stream_path(args.stream_path)
    bind_ip = args.bind_ip or get_local_ip_for_target(speaker_ip)

    audio_queue = AudioQueue()
    start_loopback_capture(audio_queue)

    StreamHandler.audio_queue = audio_queue
    StreamHandler.stream_path = stream_path

    server = ThreadingHTTPServer(("0.0.0.0", args.port), StreamHandler)
    server_thread = threading.Thread(target=server.serve_forever, name="http-stream", daemon=True)
    server_thread.start()

    stream_url = f"http://{bind_ip}:{args.port}{stream_path}"
    endpoint = fetch_av_transport_endpoint(speaker_ip)
    metadata = build_didl_metadata(stream_url, args.title)

    previous_uri = ""
    previous_uri_metadata = ""
    try:
        previous_uri, previous_uri_metadata = fetch_current_transport_source(
            endpoint,
            timeout_s=args.soap_timeout,
            retries=args.soap_retries,
            retry_delay_s=args.soap_retry_delay,
        )
    except Exception as exc:
        print(f"Warning: unable to capture previous Sonos source before redirect: {exc}")

    send_soap(
        endpoint,
        "SetAVTransportURI",
        build_set_av_transport_uri_envelope(stream_url, metadata),
        timeout_s=args.soap_timeout,
        retries=args.soap_retries,
        retry_delay_s=args.soap_retry_delay,
    )
    send_soap(
        endpoint,
        "Play",
        build_play_envelope(),
        timeout_s=args.soap_timeout,
        retries=args.soap_retries,
        retry_delay_s=args.soap_retry_delay,
    )

    write_state_file(
        args.state_file,
        {
            "speaker_ip": speaker_ip,
            "speaker_name": speaker_name,
            "endpoint": endpoint,
            "stream_url": stream_url,
            "stream_path": stream_path,
            "port": args.port,
            "title": args.title,
            "started_at_epoch": int(time.time()),
            "previous_uri": previous_uri,
            "previous_uri_metadata": previous_uri_metadata,
        },
    )

    speaker_label = speaker_name or speaker_ip
    print(f"Streaming Windows audio to Sonos speaker {speaker_label} ({speaker_ip}) via {stream_url}")

    stop_event = threading.Event()
    install_signal_handlers(stop_event)

    try:
        while not stop_event.wait(0.5):
            pass
    finally:
        try:
            send_soap(
                endpoint,
                "Stop",
                build_stop_envelope(),
                timeout_s=args.soap_timeout,
                retries=args.soap_retries,
                retry_delay_s=args.soap_retry_delay,
            )
        except Exception:
            pass
        server.shutdown()
        server.server_close()
        remove_state_file(args.state_file)

    return 0


def run_stop(args: argparse.Namespace) -> int:
    state = read_state_file(args.state_file)

    if args.speaker and args.speaker_ip:
        raise RuntimeError("Use either --speaker or --speaker-ip for stop, not both")

    explicit_selector = (args.speaker or args.speaker_ip or "").strip()
    explicit_speaker_ip = ""
    explicit_speaker_name = ""
    if explicit_selector:
        explicit_speaker = resolve_speaker_selector(explicit_selector, timeout_s=args.discover_timeout)
        explicit_speaker_ip = explicit_speaker.get("ip", "").strip()
        explicit_speaker_name = explicit_speaker.get("name", "").strip()

    state_speaker_ip = ""
    state_speaker_name = ""
    state_endpoint = ""
    state_stream_url = ""

    if state:
        state_speaker_ip_value = state.get("speaker_ip")
        if isinstance(state_speaker_ip_value, str):
            state_speaker_ip = state_speaker_ip_value.strip()

        state_speaker_name_value = state.get("speaker_name")
        if isinstance(state_speaker_name_value, str):
            state_speaker_name = state_speaker_name_value.strip()

        state_endpoint_value = state.get("endpoint")
        if isinstance(state_endpoint_value, str):
            state_endpoint = state_endpoint_value.strip()

        state_stream_url_value = state.get("stream_url")
        if isinstance(state_stream_url_value, str):
            state_stream_url = state_stream_url_value.strip()

    speaker_ip = explicit_speaker_ip or state_speaker_ip
    speaker_name = explicit_speaker_name or state_speaker_name

    endpoint = ""
    if explicit_speaker_ip:
        endpoint = fetch_av_transport_endpoint(explicit_speaker_ip)
    elif state_endpoint:
        endpoint = state_endpoint
    elif speaker_ip:
        endpoint = fetch_av_transport_endpoint(speaker_ip)

    if not speaker_ip and not endpoint:
        raise RuntimeError("No running redirect state found. Provide --speaker or --speaker-ip to force stop.")

    previous_uri = ""
    previous_uri_metadata = ""
    if state:
        previous_uri_value = state.get("previous_uri")
        if isinstance(previous_uri_value, str):
            previous_uri = previous_uri_value

        previous_uri_metadata_value = state.get("previous_uri_metadata")
        if isinstance(previous_uri_metadata_value, str):
            previous_uri_metadata = previous_uri_metadata_value

    if state_stream_url and endpoint and not explicit_selector:
        try:
            current_uri, _ = fetch_current_transport_source(
                endpoint,
                timeout_s=args.soap_timeout,
                retries=args.soap_retries,
                retry_delay_s=args.soap_retry_delay,
            )
        except Exception as exc:
            print(f"Warning: unable to verify active Sonos stream before stop: {exc}")
        else:
            if current_uri and not stream_url_matches_state(current_uri=current_uri, state_stream_url=state_stream_url):
                print(
                    "Detected that Sonos is no longer using the active WinToSonos stream; "
                    "skipping stop/restore to avoid interrupting playback"
                )
                if not args.keep_state:
                    remove_state_file(args.state_file)
                return 0

    try:
        send_soap(
            endpoint,
            "Stop",
            build_stop_envelope(),
            timeout_s=args.soap_timeout,
            retries=args.soap_retries,
            retry_delay_s=args.soap_retry_delay,
        )
    except Exception as stop_error:
        can_retry_with_discovery = bool(state_endpoint) and not explicit_selector
        if not can_retry_with_discovery:
            raise

        retry_speaker_ips: list[str] = []
        if speaker_ip:
            retry_speaker_ips.append(speaker_ip)

        recovered_speaker_ip = recover_speaker_ip_from_discovery(
            preferred_ip=speaker_ip,
            speaker_name=speaker_name,
            timeout_s=args.discover_timeout,
        )
        if recovered_speaker_ip and recovered_speaker_ip not in retry_speaker_ips:
            retry_speaker_ips.append(recovered_speaker_ip)

        retry_success = False
        for retry_speaker_ip in retry_speaker_ips:
            try:
                refreshed_endpoint = fetch_av_transport_endpoint(retry_speaker_ip)
                send_soap(
                    refreshed_endpoint,
                    "Stop",
                    build_stop_envelope(),
                    timeout_s=args.soap_timeout,
                    retries=args.soap_retries,
                    retry_delay_s=args.soap_retry_delay,
                )
                endpoint = refreshed_endpoint
                speaker_ip = retry_speaker_ip
                retry_success = True
                break
            except Exception:
                continue

        if not retry_success:
            raise stop_error

    restored_previous_source = False
    restore_error: Exception | None = None
    if args.restore_previous_source and previous_uri:
        try:
            send_soap(
                endpoint,
                "SetAVTransportURI",
                build_set_av_transport_uri_envelope(previous_uri, previous_uri_metadata),
                timeout_s=args.soap_timeout,
                retries=args.soap_retries,
                retry_delay_s=args.soap_retry_delay,
            )
            restored_previous_source = True
        except Exception as exc:
            restore_error = exc

    if restored_previous_source:
        print(f"Sent stop command to Sonos speaker {speaker_ip or 'unknown'} and restored previous source")
    else:
        print(f"Sent stop command to Sonos speaker {speaker_ip or 'unknown'}")

    if restore_error is not None:
        print(f"Warning: stop succeeded but previous Sonos source restore failed: {restore_error}")

    if not args.keep_state:
        remove_state_file(args.state_file)

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WinToSonos Windows audio redirection backend")
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser("discover", help="Discover Sonos speakers on the local network")
    discover.add_argument("--timeout", type=float, default=1.5, help="SSDP receive timeout in seconds")
    discover.add_argument("--json", action="store_true", help="Output discovery results as JSON")
    discover.set_defaults(func=run_discover)

    start = subparsers.add_parser("start", help="Start redirecting Windows output audio to a Sonos speaker")
    start.add_argument("--speaker-ip", default=None, help="Sonos speaker IP on local network")
    start.add_argument(
        "--speaker",
        default=None,
        help="Speaker selector (friendly name or IP) resolved from local-network discovery",
    )
    start.add_argument("--discover-timeout", type=float, default=1.5, help="Discovery timeout in seconds for speaker selector")
    start.add_argument("--bind-ip", default=None, help="Local LAN IP that Sonos can reach")
    start.add_argument("--port", type=int, default=8090, help="HTTP stream port")
    start.add_argument("--stream-path", default="/stream", help="HTTP stream path")
    start.add_argument("--title", default="Windows Audio", help="Displayed stream title")
    start.add_argument("--soap-timeout", type=float, default=6.0, help="Sonos SOAP HTTP timeout in seconds")
    start.add_argument("--soap-retries", type=int, default=2, help="Retry count for transient Sonos SOAP failures")
    start.add_argument(
        "--soap-retry-delay",
        type=float,
        default=0.35,
        help="Base delay in seconds between Sonos SOAP retries",
    )
    start.add_argument("--state-file", default=default_state_file(), help="Path to runtime state JSON file")
    start.set_defaults(func=run_start)

    stop = subparsers.add_parser("stop", help="Send stop command to the active Sonos stream")
    stop.add_argument("--speaker-ip", default=None, help="Speaker IP (optional when state file exists)")
    stop.add_argument(
        "--speaker",
        default=None,
        help="Speaker selector (friendly name or IP) resolved from local-network discovery",
    )
    stop.add_argument("--discover-timeout", type=float, default=1.5, help="Discovery timeout in seconds for speaker selector")
    stop.add_argument("--soap-timeout", type=float, default=6.0, help="Sonos SOAP HTTP timeout in seconds")
    stop.add_argument("--soap-retries", type=int, default=2, help="Retry count for transient Sonos SOAP failures")
    stop.add_argument(
        "--soap-retry-delay",
        type=float,
        default=0.35,
        help="Base delay in seconds between Sonos SOAP retries",
    )
    stop.add_argument("--state-file", default=default_state_file(), help="Path to runtime state JSON file")
    stop.add_argument(
        "--no-restore-previous-source",
        dest="restore_previous_source",
        action="store_false",
        help="Do not restore the speaker's previous source after stopping redirect",
    )
    stop.add_argument("--keep-state", action="store_true", help="Do not remove state file after stop")
    stop.set_defaults(func=run_stop, restore_previous_source=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
