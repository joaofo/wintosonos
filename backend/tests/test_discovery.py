from sonos_redirector.discovery import (
    parse_av_transport_control_url,
    parse_friendly_name,
    parse_location_from_ssdp,
)

SSDP_REPLY = """HTTP/1.1 200 OK\r
CACHE-CONTROL: max-age=1800\r
EXT:\r
LOCATION: http://192.168.1.15:1400/xml/device_description.xml\r
SERVER: Linux UPnP/1.0 Sonos/56.2-74200\r
ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
USN: uuid:RINCON_7CAFC4AABBCC01400::urn:schemas-upnp-org:device:ZonePlayer:1\r
\r
"""

DEVICE_DESCRIPTION = """<?xml version='1.0'?>
<root xmlns='urn:schemas-upnp-org:device-1-0'>
  <device>
    <friendlyName>Living Room</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
"""


def test_parse_location_from_ssdp_reply() -> None:
    assert parse_location_from_ssdp(SSDP_REPLY) == "http://192.168.1.15:1400/xml/device_description.xml"


def test_parse_av_transport_control_url() -> None:
    assert parse_av_transport_control_url(DEVICE_DESCRIPTION) == "/MediaRenderer/AVTransport/Control"


def test_parse_friendly_name() -> None:
    assert parse_friendly_name(DEVICE_DESCRIPTION) == "Living Room"
