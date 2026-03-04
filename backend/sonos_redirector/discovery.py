from __future__ import annotations

import socket
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

SSDP_MULTICAST = ("239.255.255.250", 1900)
SSDP_MX_SECONDS = 2
SSDP_ST = "urn:schemas-upnp-org:device:ZonePlayer:1"


def parse_location_from_ssdp(reply: str) -> str | None:
    for line in reply.splitlines():
        if line.lower().startswith("location:"):
            return line.split(":", 1)[1].strip()
    return None


def parse_av_transport_control_url(device_description_xml: str) -> str | None:
    root = ET.fromstring(device_description_xml)
    ns = {"d": "urn:schemas-upnp-org:device-1-0"}
    services = root.findall(".//d:service", ns)
    for service in services:
        service_type = service.findtext("d:serviceType", default="", namespaces=ns)
        if service_type == "urn:schemas-upnp-org:service:AVTransport:1":
            return service.findtext("d:controlURL", default=None, namespaces=ns)
    return None


def parse_friendly_name(device_description_xml: str) -> str | None:
    root = ET.fromstring(device_description_xml)
    ns = {"d": "urn:schemas-upnp-org:device-1-0"}
    return root.findtext(".//d:friendlyName", default=None, namespaces=ns)


def parse_ip_from_location(location: str) -> str | None:
    parsed = urlparse(location)
    return parsed.hostname


def discover_sonos_locations(timeout_s: float = 1.5) -> list[str]:
    query = "\r\n".join(
        [
            "M-SEARCH * HTTP/1.1",
            f"HOST: {SSDP_MULTICAST[0]}:{SSDP_MULTICAST[1]}",
            'MAN: "ssdp:discover"',
            f"MX: {SSDP_MX_SECONDS}",
            f"ST: {SSDP_ST}",
            "",
            "",
        ]
    ).encode("utf-8")

    locations: set[str] = set()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
        sock.settimeout(timeout_s)
        sock.sendto(query, SSDP_MULTICAST)
        while True:
            try:
                data, _ = sock.recvfrom(8192)
            except socket.timeout:
                break
            location = parse_location_from_ssdp(data.decode("utf-8", errors="ignore"))
            if location:
                locations.add(location)
    return sorted(locations)
