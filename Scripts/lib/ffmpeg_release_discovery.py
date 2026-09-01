"""Fail-closed discovery of the current stable FFmpeg source release."""

from __future__ import annotations

import datetime as _datetime
import json
import re
import ssl
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


CANONICAL_DOWNLOAD_URL = "https://ffmpeg.org/download.html"
CANONICAL_ORIGIN = "https://ffmpeg.org"
MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
MAX_CONFIGURATION_BYTES = 256 * 1024
VERSION_PATTERN = re.compile(
    r"(?P<major>[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)"
    r"(?:\.(?P<patch>0|[1-9][0-9]*))?\Z"
)
ASSET_PATTERN = re.compile(
    r"ffmpeg-(?P<version>.+)\.tar\.xz(?P<signature>\.asc)?\Z"
)


class DiscoveryError(RuntimeError):
    """Raised when upstream release metadata cannot be proven unambiguous."""


@dataclass
class _Anchor:
    href: str
    text_parts: list[str] = field(default_factory=list)

    @property
    def text(self) -> str:
        return " ".join(" ".join(self.text_parts).split())


@dataclass
class _ReleaseSection:
    element_id: str
    heading_parts: list[str] = field(default_factory=list)
    text_parts: list[str] = field(default_factory=list)
    anchors: list[_Anchor] = field(default_factory=list)

    @property
    def heading(self) -> str:
        return " ".join(" ".join(self.heading_parts).split())

    @property
    def text(self) -> str:
        return " ".join(" ".join(self.text_parts).split())


class _DownloadPageParser(HTMLParser):
    """Extract only the two canonical structures used as independent evidence."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.download_container_count = 0
        self.hero_container_count = 0
        self.download_anchors: list[_Anchor] = []
        self.release_sections: list[_ReleaseSection] = []
        self._div_depth = 0
        self._download_div_depth: int | None = None
        self._hero_div_depth: int | None = None
        self._current_anchor: _Anchor | None = None
        self._current_anchor_is_download = False
        self._current_anchor_section: _ReleaseSection | None = None
        self._current_section: _ReleaseSection | None = None
        self._heading_section: _ReleaseSection | None = None

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        attributes: dict[str, str | None] = {}
        for key, value in attrs:
            if key in attributes:
                raise DiscoveryError(
                    f"Duplicate {key!r} attribute makes page metadata ambiguous"
                )
            attributes[key] = value

        if tag == "div":
            self._div_depth += 1
            if attributes.get("id") == "download":
                self.download_container_count += 1
                if self._download_div_depth is not None:
                    raise DiscoveryError("Nested download containers are ambiguous")
                self._download_div_depth = self._div_depth
            classes = (attributes.get("class") or "").split()
            if (
                self._download_div_depth is not None
                and "btn-download-wrapper" in classes
            ):
                self.hero_container_count += 1
                if self._hero_div_depth is not None:
                    raise DiscoveryError("Nested source-download panels are ambiguous")
                self._hero_div_depth = self._div_depth

        if tag == "h3" and (attributes.get("id") or "").startswith("release_"):
            section = _ReleaseSection(element_id=attributes["id"] or "")
            self.release_sections.append(section)
            self._current_section = section
            self._heading_section = section

        if tag == "a":
            if self._current_anchor is not None:
                raise DiscoveryError("Nested links make release metadata ambiguous")
            href = attributes.get("href")
            if href is None:
                return
            self._current_anchor = _Anchor(href=href)
            self._current_anchor_is_download = self._hero_div_depth is not None
            self._current_anchor_section = self._current_section

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._current_anchor is not None:
            if self._current_anchor_is_download:
                self.download_anchors.append(self._current_anchor)
            if self._current_anchor_section is not None:
                self._current_anchor_section.anchors.append(self._current_anchor)
            self._current_anchor = None
            self._current_anchor_is_download = False
            self._current_anchor_section = None

        if tag == "h3":
            self._heading_section = None

        if tag == "div":
            if self._hero_div_depth == self._div_depth:
                self._hero_div_depth = None
            if self._download_div_depth == self._div_depth:
                self._download_div_depth = None
            if self._div_depth > 0:
                self._div_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._current_anchor is not None:
            self._current_anchor.text_parts.append(data)
        if self._current_section is not None:
            self._current_section.text_parts.append(data)
        if self._heading_section is not None:
            self._heading_section.heading_parts.append(data)

    def ensure_critical_elements_closed(self) -> None:
        if (
            self._download_div_depth is not None
            or self._hero_div_depth is not None
            or self._current_anchor is not None
            or self._heading_section is not None
        ):
            raise DiscoveryError("Release metadata contains unclosed critical elements")


@dataclass(frozen=True)
class _Asset:
    kind: str
    url: str
    version: str


class _CanonicalRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> Request | None:
        validate_remote_document_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _version_tuple(version: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:
        raise DiscoveryError(
            f"Version is not a stable FFmpeg release identifier: {version!r}"
        )
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch") or 0),
    )


def _release_branch(version: str) -> str:
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:  # Kept local so callers cannot bypass strict validation.
        raise DiscoveryError(f"Invalid FFmpeg release version: {version!r}")
    return f"{match.group('major')}.{match.group('minor')}"


def _split_url(url: str, description: str) -> SplitResult:
    try:
        parsed = urlsplit(url)
        # Accessing port performs validation that urlsplit otherwise defers.
        parsed.port
    except ValueError as error:
        raise DiscoveryError(f"Malformed {description} URL: {url!r}") from error
    return parsed


def _canonical_asset_url(url: str, *, expected_kind: str | None = None) -> _Asset:
    try:
        resolved = urljoin(f"{CANONICAL_ORIGIN}/download.html", url)
    except ValueError as error:
        raise DiscoveryError(f"Malformed release asset URL: {url!r}") from error
    parsed = _split_url(resolved, "release asset")
    if (
        parsed.scheme != "https"
        or parsed.hostname != "ffmpeg.org"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.query
        or parsed.fragment
    ):
        raise DiscoveryError(f"Release asset is not a canonical HTTPS URL: {resolved}")

    filename = parsed.path.rsplit("/", 1)[-1]
    match = ASSET_PATTERN.fullmatch(filename)
    if match is None:
        raise DiscoveryError(f"Unexpected FFmpeg xz asset name: {filename!r}")
    version = match.group("version")
    _version_tuple(version)
    kind = "signature" if match.group("signature") else "source"
    if expected_kind is not None and kind != expected_kind:
        raise DiscoveryError(f"Expected a {expected_kind} asset, found {kind}")

    expected_path = f"/releases/ffmpeg-{version}.tar.xz"
    if kind == "signature":
        expected_path += ".asc"
    if parsed.path != expected_path:
        raise DiscoveryError(f"Release asset has a noncanonical path: {parsed.path}")
    return _Asset(kind=kind, url=f"{CANONICAL_ORIGIN}{expected_path}", version=version)


def _looks_like_xz_asset(href: str) -> bool:
    try:
        resolved = urljoin(f"{CANONICAL_ORIGIN}/download.html", href)
    except ValueError as error:
        raise DiscoveryError(f"Malformed release link URL: {href!r}") from error
    path = _split_url(resolved, "release link").path
    filename = path.rsplit("/", 1)[-1]
    return filename.startswith("ffmpeg-") and (
        filename.endswith(".tar.xz") or filename.endswith(".tar.xz.asc")
    )


def _only(items: list[Any], description: str) -> Any:
    if len(items) != 1:
        raise DiscoveryError(
            f"Expected exactly one {description}; found {len(items)}"
        )
    return items[0]


def discover_document(document: str, configured_version: str) -> dict[str, Any]:
    """Return deterministic release metadata proven by two page structures."""

    configured_tuple = _version_tuple(configured_version)
    parser = _DownloadPageParser()
    try:
        parser.feed(document)
        parser.close()
        parser.ensure_critical_elements_closed()
    except DiscoveryError:
        raise
    except Exception as error:
        raise DiscoveryError(f"Could not parse FFmpeg download page: {error}") from error

    if parser.download_container_count != 1:
        raise DiscoveryError(
            "Expected exactly one download container; "
            f"found {parser.download_container_count}"
        )
    if parser.hero_container_count != 1:
        raise DiscoveryError(
            "Expected exactly one source-download panel; "
            f"found {parser.hero_container_count}"
        )

    hero_assets = [
        _canonical_asset_url(anchor.href, expected_kind="source")
        for anchor in parser.download_anchors
        if _looks_like_xz_asset(anchor.href)
    ]
    hero_asset = _only(hero_assets, "stable source link in the download container")
    hero_anchor = _only(
        [
            anchor
            for anchor in parser.download_anchors
            if _looks_like_xz_asset(anchor.href)
        ],
        "stable source anchor in the download container",
    )
    expected_filename = f"ffmpeg-{hero_asset.version}.tar.xz"
    if expected_filename not in hero_anchor.text:
        raise DiscoveryError(
            "The download link label does not identify its source archive"
        )

    expected_heading = f"FFmpeg {hero_asset.version}"
    expected_section_id = f"release_{_release_branch(hero_asset.version)}"
    release_sections = [
        section
        for section in parser.release_sections
        if section.element_id == expected_section_id
        and (
            section.heading == expected_heading
            or section.heading.startswith(f"{expected_heading} ")
        )
    ]
    section = _only(release_sections, "matching stable release section")

    release_statement = re.compile(
        rf"\b{re.escape(hero_asset.version)} was released on "
        r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\. "
        r"It is the latest stable FFmpeg release\b"
    )
    release_dates = [
        match.group("date") for match in release_statement.finditer(section.text)
    ]
    release_date = _only(release_dates, "latest-stable release statement")
    try:
        _datetime.date.fromisoformat(release_date)
    except ValueError as error:
        raise DiscoveryError(f"Invalid upstream release date: {release_date}") from error

    section_assets = [
        _canonical_asset_url(anchor.href)
        for anchor in section.anchors
        if _looks_like_xz_asset(anchor.href)
    ]
    section_source = _only(
        [asset for asset in section_assets if asset.kind == "source"],
        "xz source link in the stable release section",
    )
    section_signature = _only(
        [asset for asset in section_assets if asset.kind == "signature"],
        "xz signature link in the stable release section",
    )
    if section_source != hero_asset:
        raise DiscoveryError("The download and release sections identify different sources")
    if section_signature.version != hero_asset.version:
        raise DiscoveryError("The source and signature identify different releases")
    if section_signature.url != f"{hero_asset.url}.asc":
        raise DiscoveryError("The signature URL does not correspond to the source URL")

    discovered_tuple = _version_tuple(hero_asset.version)
    if discovered_tuple < configured_tuple:
        raise DiscoveryError(
            "Upstream discovery would roll back FFmpeg from "
            f"{configured_version} to {hero_asset.version}"
        )
    if discovered_tuple == configured_tuple and hero_asset.version != configured_version:
        raise DiscoveryError(
            "Equivalent FFmpeg versions use different canonical spelling: "
            f"{configured_version} and {hero_asset.version}"
        )

    return {
        "configuredVersion": configured_version,
        "release": {
            "releaseDate": release_date,
            "signatureURL": section_signature.url,
            "sourceURL": hero_asset.url,
            "version": hero_asset.version,
        },
        "schemaVersion": 1,
        "updateAvailable": discovered_tuple > configured_tuple,
    }


def validate_remote_document_url(url: str) -> None:
    parsed = _split_url(url, "remote discovery input")
    if (
        parsed.scheme != "https"
        or parsed.hostname != "ffmpeg.org"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.path != "/download.html"
        or parsed.query
        or parsed.fragment
    ):
        raise DiscoveryError(
            "Remote discovery input must be exactly " f"{CANONICAL_DOWNLOAD_URL}"
        )


def _read_limited(path: Path, limit: int, description: str) -> bytes:
    try:
        with path.open("rb") as stream:
            data = stream.read(limit + 1)
    except OSError as error:
        raise DiscoveryError(f"Could not read {description} {path}: {error}") from error
    if len(data) > limit:
        raise DiscoveryError(f"{description.capitalize()} exceeds {limit} bytes")
    return data


def load_document(source: str, timeout_seconds: float = 30.0) -> str:
    parsed = _split_url(source, "discovery input")
    if parsed.scheme:
        validate_remote_document_url(source)
        request = Request(
            source,
            headers={
                "Accept": "text/html",
                "Accept-Encoding": "identity",
                "User-Agent": "swift-ffmpeg-release-discovery/1",
            },
            method="GET",
        )
        opener = build_opener(
            _CanonicalRedirectHandler(),
            # Explicit context keeps certificate verification enabled.
            HTTPSHandler(context=ssl.create_default_context()),
        )
        try:
            with opener.open(request, timeout=timeout_seconds) as response:
                validate_remote_document_url(response.geturl())
                content_type = response.headers.get_content_type()
                if content_type != "text/html":
                    raise DiscoveryError(
                        f"Unexpected discovery response content type: {content_type}"
                    )
                content_length = response.headers.get("Content-Length")
                if content_length is not None:
                    try:
                        if int(content_length) > MAX_DOCUMENT_BYTES:
                            raise DiscoveryError("Discovery response is too large")
                    except ValueError as error:
                        raise DiscoveryError(
                            "Invalid discovery response Content-Length"
                        ) from error
                data = response.read(MAX_DOCUMENT_BYTES + 1)
        except DiscoveryError:
            raise
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise DiscoveryError(f"Could not fetch FFmpeg download page: {error}") from error
        if len(data) > MAX_DOCUMENT_BYTES:
            raise DiscoveryError("Discovery response is too large")
    else:
        data = _read_limited(Path(source), MAX_DOCUMENT_BYTES, "fixture")

    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise DiscoveryError("Discovery input is not valid UTF-8") from error


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DiscoveryError(f"Duplicate configuration key: {key}")
        result[key] = value
    return result


def load_configured_version(path: Path) -> str:
    data = _read_limited(path, MAX_CONFIGURATION_BYTES, "configuration")
    try:
        document = json.loads(
            data.decode("utf-8", errors="strict"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except DiscoveryError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscoveryError(f"Invalid release configuration: {error}") from error
    if not isinstance(document, dict):
        raise DiscoveryError("Release configuration must be a JSON object")
    ffmpeg = document.get("ffmpeg")
    if not isinstance(ffmpeg, dict) or not isinstance(ffmpeg.get("version"), str):
        raise DiscoveryError("Release configuration must contain ffmpeg.version")
    version = ffmpeg["version"]
    _version_tuple(version)
    return version


def render_json(result: dict[str, Any]) -> str:
    return json.dumps(result, indent=2, sort_keys=True) + "\n"
