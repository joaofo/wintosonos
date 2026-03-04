from sonos_redirector.soap import (
    build_didl_metadata,
    build_play_envelope,
    build_set_av_transport_uri_envelope,
    build_stop_envelope,
)


def test_build_didl_metadata_contains_stream_url_and_title() -> None:
    xml = build_didl_metadata("http://192.168.1.2:8080/stream", "PC Audio")
    assert "http://192.168.1.2:8080/stream" in xml
    assert "PC Audio" in xml
    assert "object.item.audioItem.musicTrack" in xml


def test_set_av_transport_uri_envelope_wraps_metadata_and_uri() -> None:
    metadata = "<meta />"
    envelope = build_set_av_transport_uri_envelope("http://stream", metadata)
    assert "SetAVTransportURI" in envelope
    assert "<CurrentURI>http://stream</CurrentURI>" in envelope
    assert "<CurrentURIMetaData>&lt;meta /&gt;</CurrentURIMetaData>" in envelope


def test_build_play_envelope_uses_speed_one() -> None:
    envelope = build_play_envelope()
    assert "<u:Play" in envelope
    assert "<Speed>1</Speed>" in envelope


def test_build_stop_envelope_has_stop_action() -> None:
    envelope = build_stop_envelope()
    assert "<u:Stop" in envelope
    assert "<InstanceID>0</InstanceID>" in envelope
