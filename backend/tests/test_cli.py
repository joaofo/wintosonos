from sonos_redirector.redirector import build_parser


def test_start_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["start", "--speaker-ip", "192.168.1.10"])
    assert args.port == 8090
    assert args.stream_path == "/stream"
    assert args.title == "Windows Audio"


def test_discover_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["discover"])
    assert args.timeout == 1.5
    assert args.json is False


def test_stop_parser_defaults() -> None:
    parser = build_parser()
    args = parser.parse_args(["stop"])
    assert args.keep_state is False
