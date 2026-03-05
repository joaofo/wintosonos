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
    assert args.soap_timeout == 6.0
    assert args.soap_retries == 2
    assert args.soap_retry_delay == 0.35


def test_discover_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["discover"])
    assert args.timeout == 1.5
    assert args.json is False


def test_stop_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop"])
    assert args.keep_state is False
    assert args.restore_previous_source is True
    assert args.soap_timeout == 6.0
    assert args.soap_retries == 2
    assert args.soap_retry_delay == 0.35


def test_stop_parser_can_disable_previous_source_restore() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop", "--no-restore-previous-source"])
    assert args.restore_previous_source is False


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
