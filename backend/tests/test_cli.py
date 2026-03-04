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
    assert args.soap_timeout == 6.0
    assert args.soap_retries == 2
    assert args.soap_retry_delay == 0.35


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
