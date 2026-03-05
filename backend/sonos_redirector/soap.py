from __future__ import annotations

from html import escape
import xml.etree.ElementTree as ET


def build_didl_metadata(stream_url: str, title: str) -> str:
    safe_title = escape(title)
    safe_url = escape(stream_url)
    return (
        '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        '<item id="-1" parentID="-1" restricted="true">'
        f"<dc:title>{safe_title}</dc:title>"
        "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        f"<res protocolInfo=\"http-get:*:audio/wav:*\">{safe_url}</res>"
        "</item>"
        "</DIDL-Lite>"
    )


def build_set_av_transport_uri_envelope(stream_url: str, metadata_xml: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        "<InstanceID>0</InstanceID>"
        f"<CurrentURI>{escape(stream_url)}</CurrentURI>"
        f"<CurrentURIMetaData>{escape(metadata_xml)}</CurrentURIMetaData>"
        "</u:SetAVTransportURI>"
        "</s:Body>"
        "</s:Envelope>"
    )


def build_play_envelope() -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        "<InstanceID>0</InstanceID>"
        "<Speed>1</Speed>"
        "</u:Play>"
        "</s:Body>"
        "</s:Envelope>"
    )


def build_stop_envelope() -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        "<InstanceID>0</InstanceID>"
        "</u:Stop>"
        "</s:Body>"
        "</s:Envelope>"
    )


def build_get_media_info_envelope() -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        "<InstanceID>0</InstanceID>"
        "</u:GetMediaInfo>"
        "</s:Body>"
        "</s:Envelope>"
    )


def parse_current_transport_uri(soap_response_xml: str) -> tuple[str, str]:
    try:
        root = ET.fromstring(soap_response_xml)
    except ET.ParseError as exc:
        raise ValueError(f"Invalid Sonos SOAP XML response: {exc}") from exc

    current_uri = ""
    current_uri_metadata = ""

    for element in root.iter():
        tag_name = element.tag.rsplit("}", 1)[-1]
        if tag_name == "CurrentURI":
            current_uri = (element.text or "").strip()
        elif tag_name == "CurrentURIMetaData":
            current_uri_metadata = (element.text or "").strip()

    return current_uri, current_uri_metadata
