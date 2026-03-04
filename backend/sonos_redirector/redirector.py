from __future__ import annotations

import argparse
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
from urllib.parse import urljoin
from urllib.request import Request, urlopen

from sonos_redirector.discovery import (
    discover_sonos_locations,
    parse_av_transport_control_url,
    parse_friendly_name,
    parse_ip_from_location,
)
from sonos_redirector.soap import (
    build_didl_metadata,
    build_play_envelope,
    build_set_av_transport_uri_envelope,
    build_stop_envelope,
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
) -> None:
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
            with urlopen(req, timeout=timeout_s):
                return
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
    stream_path = normalize_stream_path(args.stream_path)
    bind_ip = args.bind_ip or get_local_ip_for_target(args.speaker_ip)

    audio_queue = AudioQueue()
    start_loopback_capture(audio_queue)

    StreamHandler.audio_queue = audio_queue
    StreamHandler.stream_path = stream_path

    server = ThreadingHTTPServer(("0.0.0.0", args.port), StreamHandler)
    server_thread = threading.Thread(target=server.serve_forever, name="http-stream", daemon=True)
    server_thread.start()

    stream_url = f"http://{bind_ip}:{args.port}{stream_path}"
    endpoint = fetch_av_transport_endpoint(args.speaker_ip)
    metadata = build_didl_metadata(stream_url, args.title)

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
            "speaker_ip": args.speaker_ip,
            "endpoint": endpoint,
            "stream_url": stream_url,
            "stream_path": stream_path,
            "port": args.port,
            "title": args.title,
            "started_at_epoch": int(time.time()),
        },
    )

    print(f"Streaming Windows audio to Sonos speaker {args.speaker_ip} via {stream_url}")

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

    speaker_ip = args.speaker_ip
    endpoint = None
    if state:
        speaker_ip = speaker_ip or str(state.get("speaker_ip", ""))
        endpoint_value = state.get("endpoint")
        if isinstance(endpoint_value, str) and endpoint_value:
            endpoint = endpoint_value

    if not speaker_ip and not endpoint:
        raise RuntimeError("No running redirect state found. Provide --speaker-ip to force stop.")

    if endpoint is None:
        endpoint = fetch_av_transport_endpoint(str(speaker_ip))

    send_soap(
        endpoint,
        "Stop",
        build_stop_envelope(),
        timeout_s=args.soap_timeout,
        retries=args.soap_retries,
        retry_delay_s=args.soap_retry_delay,
    )
    print(f"Sent stop command to Sonos speaker {speaker_ip or 'unknown'}")

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
    start.add_argument("--speaker-ip", required=True, help="Sonos speaker IP on local network")
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
    stop.add_argument("--soap-timeout", type=float, default=6.0, help="Sonos SOAP HTTP timeout in seconds")
    stop.add_argument("--soap-retries", type=int, default=2, help="Retry count for transient Sonos SOAP failures")
    stop.add_argument(
        "--soap-retry-delay",
        type=float,
        default=0.35,
        help="Base delay in seconds between Sonos SOAP retries",
    )
    stop.add_argument("--state-file", default=default_state_file(), help="Path to runtime state JSON file")
    stop.add_argument("--keep-state", action="store_true", help="Do not remove state file after stop")
    stop.set_defaults(func=run_stop)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
