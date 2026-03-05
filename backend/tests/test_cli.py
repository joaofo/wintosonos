import json
import tempfile
from urllib.error import URLError

import sonos_redirector.redirector as redirector
from sonos_redirector.redirector import build_parser


def test_start_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["start", "--speaker-ip", "192.168.1.10"])
    assert args.port == 8090
    assert args.stream_path == "/stream"
    assert args.title == "Windows Audio"
    assert args.discover_timeout == 1.5
    assert args.speaker is None
    assert args.soap_timeout == 6.0
    assert args.soap_retries == 2
    assert args.soap_retry_delay == 0.35


def test_discover_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["discover"])
    assert args.timeout == 1.5
    assert args.json is False


def test_start_parser_accepts_speaker_selector() -> None:
    parser = build_parser()
    args = parser.parse_args(["start", "--speaker", "Living Room"])
    assert args.speaker == "Living Room"
    assert args.speaker_ip is None


def test_run_start_rejects_conflicting_speaker_arguments() -> None:
    parser = build_parser()
    args = parser.parse_args(["start", "--speaker", "Living Room", "--speaker-ip", "192.168.1.10"])
    try:
        redirector.run_start(args)
        assert False, "Expected RuntimeError"
    except RuntimeError as exc:
        assert "either --speaker or --speaker-ip" in str(exc)


def test_stop_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop"])
    assert args.keep_state is False
    assert args.restore_previous_source is True
    assert args.discover_timeout == 1.5
    assert args.speaker is None
    assert args.soap_timeout == 6.0
    assert args.soap_retries == 2
    assert args.soap_retry_delay == 0.35


def test_stop_parser_can_disable_previous_source_restore() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop", "--no-restore-previous-source"])
    assert args.restore_previous_source is False


def test_stop_parser_accepts_speaker_selector() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop", "--speaker", "Office"])

    assert args.speaker == "Office"
    assert args.speaker_ip is None


def test_run_stop_rejects_conflicting_speaker_arguments() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop", "--speaker", "Office", "--speaker-ip", "192.168.1.10"])
    try:
        redirector.run_stop(args)
        assert False, "Expected RuntimeError"
    except RuntimeError as exc:
        assert "either --speaker or --speaker-ip" in str(exc)


def test_resolve_speaker_selector_accepts_ip_without_discovery() -> None:
    calls = {"count": 0}
    original_discover_speakers = redirector.discover_speakers

    def fake_discover_speakers(timeout_s):
        del timeout_s
        calls["count"] += 1
        return []

    redirector.discover_speakers = fake_discover_speakers
    try:
        resolved = redirector.resolve_speaker_selector("192.168.1.44", timeout_s=1.5)
    finally:
        redirector.discover_speakers = original_discover_speakers

    assert resolved["ip"] == "192.168.1.44"
    assert calls["count"] == 0


def test_resolve_speaker_selector_matches_name_case_insensitive() -> None:
    original_discover_speakers = redirector.discover_speakers

    def fake_discover_speakers(timeout_s):
        del timeout_s
        return [
            {"name": "Living Room", "ip": "192.168.1.51", "location": ""},
            {"name": "Office", "ip": "192.168.1.52", "location": ""},
        ]

    redirector.discover_speakers = fake_discover_speakers
    try:
        resolved = redirector.resolve_speaker_selector("living room", timeout_s=1.5)
    finally:
        redirector.discover_speakers = original_discover_speakers

    assert resolved["name"] == "Living Room"
    assert resolved["ip"] == "192.168.1.51"


def test_resolve_speaker_selector_raises_for_ambiguous_name() -> None:
    original_discover_speakers = redirector.discover_speakers

    def fake_discover_speakers(timeout_s):
        del timeout_s
        return [
            {"name": "Kitchen", "ip": "192.168.1.61", "location": ""},
            {"name": "Kitchen", "ip": "192.168.1.62", "location": ""},
        ]

    redirector.discover_speakers = fake_discover_speakers
    try:
        try:
            redirector.resolve_speaker_selector("Kitchen", timeout_s=1.5)
            assert False, "Expected RuntimeError"
        except RuntimeError as exc:
            assert "matched multiple speakers" in str(exc)
    finally:
        redirector.discover_speakers = original_discover_speakers


def test_send_soap_retries_and_succeeds() -> None:
    calls = {"count": 0}

    class DummyResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original_urlopen = redirector.urlopen

    def flaky_urlopen(request, timeout):
        del request, timeout
        calls["count"] += 1
        if calls["count"] == 1:
            raise URLError("temporary network issue")
        return DummyResponse()

    redirector.urlopen = flaky_urlopen
    try:
        redirector.send_soap(
            "http://speaker:1400/MediaRenderer/AVTransport/Control",
            "Play",
            "<xml/>",
            timeout_s=0.1,
            retries=2,
            retry_delay_s=0,
        )
    finally:
        redirector.urlopen = original_urlopen

    assert calls["count"] == 2


def test_send_soap_raises_after_retry_exhausted() -> None:
    calls = {"count": 0}
    original_urlopen = redirector.urlopen

    def always_fail(request, timeout):
        del request, timeout
        calls["count"] += 1
        raise URLError("still offline")

    redirector.urlopen = always_fail
    try:
        try:
            redirector.send_soap(
                "http://speaker:1400/MediaRenderer/AVTransport/Control",
                "Stop",
                "<xml/>",
                timeout_s=0.1,
                retries=1,
                retry_delay_s=0,
            )
            assert False, "Expected RuntimeError"
        except RuntimeError as exc:
            assert "Stop" in str(exc)
            assert "after 2 attempt(s)" in str(exc)
    finally:
        redirector.urlopen = original_urlopen

    assert calls["count"] == 2


def test_fetch_current_transport_source_uses_get_media_info() -> None:
    call = {}
    original_send_soap = redirector.send_soap

    def fake_send_soap(endpoint, action, payload, **kwargs):
        call["endpoint"] = endpoint
        call["action"] = action
        call["payload"] = payload
        call["kwargs"] = kwargs
        return (
            "<?xml version='1.0'?><Envelope><Body><GetMediaInfoResponse>"
            "<CurrentURI>x-rincon-queue:RINCON_ABC#0</CurrentURI>"
            "<CurrentURIMetaData>&lt;DIDL-Lite&gt;queue&lt;/DIDL-Lite&gt;</CurrentURIMetaData>"
            "</GetMediaInfoResponse></Body></Envelope>"
        )

    redirector.send_soap = fake_send_soap
    try:
        uri, metadata = redirector.fetch_current_transport_source("http://speaker:1400/MediaRenderer/AVTransport/Control")
    finally:
        redirector.send_soap = original_send_soap

    assert call["action"] == "GetMediaInfo"
    assert "GetMediaInfo" in call["payload"]
    assert call["kwargs"]["expect_response"] is True
    assert uri == "x-rincon-queue:RINCON_ABC#0"
    assert metadata == "<DIDL-Lite>queue</DIDL-Lite>"


def test_run_stop_restores_previous_source_from_state_file() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                    "previous_uri": "x-rincon-queue:RINCON_00112233445501400#0",
                    "previous_uri_metadata": "<DIDL-Lite><dc:title>Queue</dc:title></DIDL-Lite>",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file])

        soap_calls = []
        original_send_soap = redirector.send_soap

        def fake_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            return None

        redirector.send_soap = fake_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert [call[1] for call in soap_calls] == ["Stop", "SetAVTransportURI"]
        assert "x-rincon-queue:RINCON_00112233445501400#0" in soap_calls[1][2]
        assert "&lt;DIDL-Lite&gt;" in soap_calls[1][2]
        assert not redirector.Path(state_file).exists()


def test_run_stop_no_restore_flag_skips_previous_source_restore() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                    "previous_uri": "x-rincon-queue:RINCON_00112233445501400#0",
                    "previous_uri_metadata": "<DIDL-Lite><dc:title>Queue</dc:title></DIDL-Lite>",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file, "--no-restore-previous-source"])

        soap_calls = []
        original_send_soap = redirector.send_soap

        def fake_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            return None

        redirector.send_soap = fake_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert [call[1] for call in soap_calls] == ["Stop"]


def test_run_stop_uses_explicit_speaker_ip_to_resolve_endpoint() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(
            [
                "stop",
                "--state-file",
                state_file,
                "--speaker-ip",
                "192.168.1.99",
                "--no-restore-previous-source",
            ]
        )

        fetch_calls = []
        soap_calls = []
        original_fetch_av_transport_endpoint = redirector.fetch_av_transport_endpoint
        original_send_soap = redirector.send_soap

        def fake_fetch_av_transport_endpoint(speaker_ip):
            fetch_calls.append(speaker_ip)
            return f"http://{speaker_ip}:1400/MediaRenderer/AVTransport/Control"

        def fake_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            return None

        redirector.fetch_av_transport_endpoint = fake_fetch_av_transport_endpoint
        redirector.send_soap = fake_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.fetch_av_transport_endpoint = original_fetch_av_transport_endpoint
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert fetch_calls == ["192.168.1.99"]
        assert [call[1] for call in soap_calls] == ["Stop"]
        assert soap_calls[0][0] == "http://192.168.1.99:1400/MediaRenderer/AVTransport/Control"


def test_run_stop_retries_with_discovered_endpoint_when_state_endpoint_fails() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        stale_endpoint = "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control"
        refreshed_endpoint = "http://192.168.1.51:1400/MediaRenderer/AVTransport/Control"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.51",
                    "endpoint": stale_endpoint,
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file, "--no-restore-previous-source"])

        fetch_calls = []
        soap_calls = []
        original_fetch_av_transport_endpoint = redirector.fetch_av_transport_endpoint
        original_send_soap = redirector.send_soap
        original_discover_speakers = redirector.discover_speakers

        def fake_fetch_av_transport_endpoint(speaker_ip):
            fetch_calls.append(speaker_ip)
            return refreshed_endpoint

        def fake_discover_speakers(timeout_s):
            del timeout_s
            return []

        def flaky_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            if action == "Stop" and endpoint == stale_endpoint:
                raise RuntimeError("stale endpoint")
            return None

        redirector.fetch_av_transport_endpoint = fake_fetch_av_transport_endpoint
        redirector.send_soap = flaky_send_soap
        redirector.discover_speakers = fake_discover_speakers
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.fetch_av_transport_endpoint = original_fetch_av_transport_endpoint
            redirector.send_soap = original_send_soap
            redirector.discover_speakers = original_discover_speakers

        assert exit_code == 0
        assert fetch_calls == ["192.168.1.51"]
        assert [call[0] for call in soap_calls] == [stale_endpoint, refreshed_endpoint]
        assert [call[1] for call in soap_calls] == ["Stop", "Stop"]


def test_run_stop_recovers_by_speaker_name_when_ip_changed() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        stale_endpoint = "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control"
        refreshed_endpoint = "http://192.168.1.99:1400/MediaRenderer/AVTransport/Control"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "speaker_name": "Living Room",
                    "endpoint": stale_endpoint,
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file, "--no-restore-previous-source"])

        fetch_calls = []
        soap_calls = []
        original_fetch_av_transport_endpoint = redirector.fetch_av_transport_endpoint
        original_send_soap = redirector.send_soap
        original_discover_speakers = redirector.discover_speakers

        def fake_fetch_av_transport_endpoint(speaker_ip):
            fetch_calls.append(speaker_ip)
            if speaker_ip == "192.168.1.50":
                raise RuntimeError("speaker IP changed")
            return refreshed_endpoint

        def fake_discover_speakers(timeout_s):
            del timeout_s
            return [{"name": "Living Room", "ip": "192.168.1.99", "location": ""}]

        def flaky_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            if action == "Stop" and endpoint == stale_endpoint:
                raise RuntimeError("stale endpoint")
            return None

        redirector.fetch_av_transport_endpoint = fake_fetch_av_transport_endpoint
        redirector.send_soap = flaky_send_soap
        redirector.discover_speakers = fake_discover_speakers
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.fetch_av_transport_endpoint = original_fetch_av_transport_endpoint
            redirector.send_soap = original_send_soap
            redirector.discover_speakers = original_discover_speakers

        assert exit_code == 0
        assert fetch_calls == ["192.168.1.50", "192.168.1.99"]
        assert [call[0] for call in soap_calls] == [stale_endpoint, refreshed_endpoint]
        assert [call[1] for call in soap_calls] == ["Stop", "Stop"]


def test_run_stop_restore_failure_still_succeeds_and_cleans_state() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                    "previous_uri": "x-rincon-queue:RINCON_00112233445501400#0",
                    "previous_uri_metadata": "<DIDL-Lite><dc:title>Queue</dc:title></DIDL-Lite>",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file])

        soap_calls = []
        original_send_soap = redirector.send_soap

        def flaky_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            if action == "SetAVTransportURI":
                raise RuntimeError("temporary restore failure")
            return None

        redirector.send_soap = flaky_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert [call[1] for call in soap_calls] == ["Stop", "SetAVTransportURI"]
        assert not redirector.Path(state_file).exists()


def test_stream_url_matches_state_handles_default_http_port() -> None:
    assert (
        redirector.stream_url_matches_state(
            current_uri="http://192.168.1.50/stream",
            state_stream_url="http://192.168.1.50:80/stream",
        )
        is True
    )


def test_run_stop_skips_when_speaker_no_longer_plays_wintosonos_stream() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                    "stream_url": "http://192.168.1.11:8090/stream",
                    "previous_uri": "x-rincon-queue:RINCON_00112233445501400#0",
                    "previous_uri_metadata": "<DIDL-Lite><dc:title>Queue</dc:title></DIDL-Lite>",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file])

        soap_calls = []
        original_fetch_current_transport_source = redirector.fetch_current_transport_source
        original_send_soap = redirector.send_soap

        def fake_fetch_current_transport_source(endpoint, **kwargs):
            del endpoint, kwargs
            return "x-rincon-queue:RINCON_ABC#0", ""

        def fake_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            return None

        redirector.fetch_current_transport_source = fake_fetch_current_transport_source
        redirector.send_soap = fake_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.fetch_current_transport_source = original_fetch_current_transport_source
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert soap_calls == []
        assert not redirector.Path(state_file).exists()


def test_run_stop_continues_when_wintosonos_stream_is_still_active() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        state_file = f"{temp_dir}/redirect-state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "speaker_ip": "192.168.1.50",
                    "endpoint": "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control",
                    "stream_url": "http://192.168.1.11:8090/stream",
                },
                f,
            )

        parser = build_parser()
        args = parser.parse_args(["stop", "--state-file", state_file, "--no-restore-previous-source"])

        soap_calls = []
        original_fetch_current_transport_source = redirector.fetch_current_transport_source
        original_send_soap = redirector.send_soap

        def fake_fetch_current_transport_source(endpoint, **kwargs):
            del endpoint, kwargs
            return "http://192.168.1.11:8090/stream", ""

        def fake_send_soap(endpoint, action, payload, **kwargs):
            soap_calls.append((endpoint, action, payload, kwargs))
            return None

        redirector.fetch_current_transport_source = fake_fetch_current_transport_source
        redirector.send_soap = fake_send_soap
        try:
            exit_code = redirector.run_stop(args)
        finally:
            redirector.fetch_current_transport_source = original_fetch_current_transport_source
            redirector.send_soap = original_send_soap

        assert exit_code == 0
        assert [call[1] for call in soap_calls] == ["Stop"]
        assert not redirector.Path(state_file).exists()
