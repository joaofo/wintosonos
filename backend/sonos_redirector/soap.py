from __future__ import annotations

from html import escape


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
