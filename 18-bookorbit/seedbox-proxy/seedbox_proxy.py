"""Transmission RPC proxy that holds back "finished" until the files are local.

BookOrbit's request feature grabs torrents into a Transmission daemon on a remote
seedbox and imports a download as soon as Transmission reports it finished, from
a local path it maps the seedbox path onto. Nothing moves the files home, and an
import that finds them missing fails the attempt. This proxy sits between the
two: every call is forwarded to the seedbox unchanged (BookOrbit's own
Transmission login and the X-Transmission-Session-Id handshake included), except
that in torrent-get answers a finished torrent in the category folder is
reported as still downloading until its files have been copied over FTPS into
LOCAL_ROOT. Then the real status goes through and BookOrbit imports the local
copy.

BookOrbit puts a category's torrents in `<download-dir>/<category>` and asks
Transmission for download-dir (session-get) before every add, so the proxy
learns the folder from that answer and keeps it in LOCAL_ROOT/.proxy; no
seedbox path is configured by hand. FTP_ROOT is where download-dir appears in
the FTP login (the seedbox chroots FTP into it, hence the default `/`).

State lives on disk under LOCAL_ROOT/.proxy so a restart resumes: a torrent is
done once `done/<hash>` exists, which is written only after its files have been
renamed into place. Local copies are deleted RETENTION_DAYS after they landed
(BookOrbit has linked or copied them into its Book Dock by then); the markers
stay, so a torrent BookOrbit still polls for seeding is never fetched again.
"""

import ftplib
import http.server
import json
import logging
import os
import queue
import shutil
import socketserver
import ssl
import threading
import time
import urllib.error
import urllib.request

UPSTREAM = os.environ["UPSTREAM_URL"].rstrip("/")  # e.g. https://host (RPC path is forwarded as-is)
CATEGORY = os.environ.get("CATEGORY", "bookorbit").strip("/")  # the category set on BookOrbit's client
LOCAL_ROOT = os.environ["LOCAL_ROOT"].rstrip("/")  # where the category folder is mirrored for BookOrbit
FTP_ROOT = os.environ.get("FTP_ROOT", "/").rstrip("/")  # download-dir as the FTP login sees it
FTP_HOST = os.environ["FTP_HOST"]
FTP_PORT = int(os.environ.get("FTP_PORT", "21"))
FTP_USER = os.environ["FTP_USERNAME"]
FTP_PASSWORD = os.environ["FTP_PASSWORD"]
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9091"))
RETENTION_DAYS = float(os.environ.get("RETENTION_DAYS", "7"))
RPC_PATH = "/transmission/rpc"

# Transmission's status enum; BookOrbit reads 5/6 (and 0 with percentDone 1) as finished.
STATUS_STOPPED, STATUS_DOWNLOAD, STATUS_SEED_WAIT, STATUS_SEED = 0, 4, 5, 6
# Hop-by-hop headers, plus the ones a rewritten body invalidates.
SKIP_RESPONSE_HEADERS = {"connection", "keep-alive", "transfer-encoding", "content-length", "content-encoding"}

STATE_DIR = os.path.join(LOCAL_ROOT, ".proxy")
DONE_DIR = os.path.join(STATE_DIR, "done")
TMP_DIR = os.path.join(STATE_DIR, "tmp")
DOWNLOAD_DIR_FILE = os.path.join(STATE_DIR, "download-dir")

log = logging.getLogger("seedbox-proxy")
jobs: "queue.Queue[dict]" = queue.Queue()
queued: set = set()
queued_lock = threading.Lock()
download_dir: "str | None" = None


def learn_download_dir(value: "str | None") -> None:
    global download_dir
    value = (value or "").strip().rstrip("/")
    if not value or value == download_dir:
        return
    tmp = DOWNLOAD_DIR_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(value + "\n")
    os.replace(tmp, DOWNLOAD_DIR_FILE)
    download_dir = value
    log.info("learned download-dir=%s; watching %s/%s", value, value, CATEGORY)


def watch_dir() -> "str | None":
    return f"{download_dir}/{CATEGORY}" if download_dir else None


def is_done(torrent_hash: str) -> bool:
    return os.path.exists(os.path.join(DONE_DIR, torrent_hash))


def finished_upstream(t: dict) -> bool:
    status = t.get("status")
    if status in (STATUS_SEED_WAIT, STATUS_SEED):
        return True
    return status == STATUS_STOPPED and (t.get("isFinished") is True or t.get("percentDone") == 1)


def relative_to_watch(torrent_dir: str, name: str) -> "str | None":
    """The torrent's content path relative to the category folder, or None if outside it."""
    watch = watch_dir()
    path = f"{torrent_dir.rstrip('/')}/{name}"
    if not watch or not path.startswith(watch + "/"):
        return None
    rel = path[len(watch) + 1 :]
    if not rel or any(part in ("", ".", "..") for part in rel.split("/")):
        return None
    return rel


def ftp_path(rel: str) -> str:
    return f"{FTP_ROOT}/{CATEGORY}/{rel}"


def hold(t: dict) -> None:
    """Rewrite a finished torrent so BookOrbit keeps waiting (and does not call it stalled)."""
    t["status"] = STATUS_DOWNLOAD
    if "percentDone" in t:
        t["percentDone"] = 0.99
    if "isFinished" in t:
        t["isFinished"] = False


def enqueue(torrent_hash: str, rel: str) -> None:
    with queued_lock:
        if torrent_hash in queued:
            return
        queued.add(torrent_hash)
    log.info("queue hash=%s path=%s", torrent_hash, rel)
    jobs.put({"hash": torrent_hash, "rel": rel})


def filter_torrent_get(payload: dict) -> None:
    for t in (payload.get("arguments") or {}).get("torrents") or []:
        torrent_hash = (t.get("hashString") or "").lower()
        if not torrent_hash or not finished_upstream(t) or is_done(torrent_hash):
            continue
        rel = relative_to_watch(t.get("downloadDir") or "", t.get("name") or "")
        if rel is None:
            continue  # not a BookOrbit download; nothing to fetch
        enqueue(torrent_hash, rel)
        hold(t)


class ReusedSessionFTP(ftplib.FTP_TLS):
    """vsftpd refuses a TLS data connection that does not resume the control session."""

    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(conn, server_hostname=self.host, session=self.sock.session)
        return conn, size


def ftp_connect() -> ftplib.FTP_TLS:
    context = ssl.create_default_context()
    # TLS 1.3 hands out resumable sessions only after the handshake, too late for the first
    # data connection's resumption; 1.2 makes the session available immediately.
    context.maximum_version = ssl.TLSVersion.TLSv1_2
    ftp = ReusedSessionFTP(context=context, timeout=60)
    ftp.connect(FTP_HOST, FTP_PORT)
    ftp.auth()
    ftp.login(FTP_USER, FTP_PASSWORD)
    ftp.prot_p()
    return ftp


def ftp_is_dir(ftp: ftplib.FTP_TLS, path: str) -> bool:
    here = ftp.pwd()
    try:
        ftp.cwd(path)
        return True
    except ftplib.error_perm:
        return False
    finally:
        ftp.cwd(here)


def ftp_fetch(ftp: ftplib.FTP_TLS, remote: str, local: str) -> int:
    """Copy a file or directory tree; returns the number of bytes written."""
    if ftp_is_dir(ftp, remote):
        os.makedirs(local, exist_ok=True)
        written = 0
        for entry in ftp.nlst(remote):
            name = entry.rstrip("/").rsplit("/", 1)[-1]
            if name in ("", ".", ".."):
                continue
            written += ftp_fetch(ftp, f"{remote}/{name}", os.path.join(local, name))
        return written
    expected = ftp.size(remote)
    with open(local, "wb") as out:
        ftp.retrbinary(f"RETR {remote}", out.write, blocksize=1 << 20)
    actual = os.path.getsize(local)
    if expected is not None and actual != expected:
        raise IOError(f"short read on {remote}: {actual} of {expected} bytes")
    return actual


def copy_job(job: dict) -> None:
    torrent_hash, rel = job["hash"], job["rel"]
    remote = ftp_path(rel)
    final = os.path.join(LOCAL_ROOT, rel)
    staging = os.path.join(TMP_DIR, torrent_hash)
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)
    started = time.monotonic()
    ftp = ftp_connect()
    try:
        written = ftp_fetch(ftp, remote, os.path.join(staging, "content"))
    finally:
        try:
            ftp.quit()
        except Exception:
            ftp.close()
    os.makedirs(os.path.dirname(final), exist_ok=True)
    if os.path.lexists(final):
        (shutil.rmtree if os.path.isdir(final) else os.remove)(final)
    os.rename(os.path.join(staging, "content"), final)
    shutil.rmtree(staging, ignore_errors=True)
    with open(os.path.join(DONE_DIR, torrent_hash), "w") as marker:
        marker.write(rel + "\n")
    log.info("done hash=%s bytes=%d seconds=%.1f path=%s", torrent_hash, written, time.monotonic() - started, rel)


def worker() -> None:
    while True:
        job = jobs.get()
        try:
            copy_job(job)
            with queued_lock:
                queued.discard(job["hash"])
        except Exception as error:  # noqa: BLE001 - any failure is retried
            log.warning("copy failed hash=%s error=%r; retrying in 60s", job["hash"], error)
            time.sleep(60)
            jobs.put(job)


def cleaner() -> None:
    while True:
        cutoff = time.time() - RETENTION_DAYS * 86400
        for name in os.listdir(DONE_DIR):
            marker = os.path.join(DONE_DIR, name)
            try:
                if os.path.getmtime(marker) > cutoff:
                    continue
                with open(marker) as f:
                    rel = f.read().strip()
                if not rel:
                    continue
                path = os.path.join(LOCAL_ROOT, rel)
                if os.path.lexists(path):
                    (shutil.rmtree if os.path.isdir(path) else os.remove)(path)
                    log.info("expired hash=%s path=%s", name, rel)
                # Keep the marker (emptied) so the torrent is never fetched again.
                open(marker, "w").close()
            except OSError as error:
                log.warning("cleanup failed hash=%s error=%r", name, error)
        time.sleep(3600)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet: BookOrbit polls every few seconds
        pass

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"Content-Type": "text/plain"}, b"ok\n")
        else:
            self.reply(404, {"Content-Type": "text/plain"}, b"not found\n")

    def do_POST(self):
        if self.path.split("?", 1)[0] != RPC_PATH:
            self.reply(404, {"Content-Type": "text/plain"}, b"not found\n")
            return
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        forward = {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "content-type", "x-transmission-session-id")}
        request = urllib.request.Request(UPSTREAM + self.path, data=body, headers=forward, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status, headers, data = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:  # 401 and the 409 session handshake pass through
            status, headers, data = error.code, error.headers, error.read()
        except (urllib.error.URLError, OSError) as error:
            log.warning("upstream unreachable: %r", error)
            self.reply(502, {"Content-Type": "text/plain"}, b"seedbox unreachable\n")
            return

        if status == 200:
            try:
                method = json.loads(body or b"{}").get("method")
                if method == "torrent-get":
                    payload = json.loads(data)
                    filter_torrent_get(payload)
                    data = json.dumps(payload).encode()
                elif method == "session-get":
                    learn_download_dir((json.loads(data).get("arguments") or {}).get("download-dir"))
            except (ValueError, AttributeError) as error:
                log.warning("left an unparsable answer untouched: %r", error)
        out = {k: v for k, v in headers.items() if k.lower() not in SKIP_RESPONSE_HEADERS}
        self.reply(status, out, data)

    def reply(self, status: int, headers: dict, data: bytes) -> None:
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main() -> None:
    global download_dir
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for path in (DONE_DIR, TMP_DIR):
        os.makedirs(path, exist_ok=True)
    if os.path.exists(DOWNLOAD_DIR_FILE):
        with open(DOWNLOAD_DIR_FILE) as f:
            download_dir = f.read().strip() or None
    shutil.rmtree(TMP_DIR, ignore_errors=True)  # half-finished copies restart from scratch
    os.makedirs(TMP_DIR, exist_ok=True)
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=cleaner, daemon=True).start()
    log.info("listening on :%d upstream=%s watch=%s local=%s", LISTEN_PORT, UPSTREAM, watch_dir() or "(not learned yet)", LOCAL_ROOT)
    Server(("", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
