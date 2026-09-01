#!/usr/bin/env python3
"""Isolated ControlMaster + SFTP round-trip test for remote file editing."""

import errno
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

import paramiko


TEST_USER = "kiteshell-test"
TEST_PASSWORD = "non-secret-integration-test"


class PasswordServer(paramiko.ServerInterface):
    def __init__(self):
        self.authenticated = False

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, password):
        if username == TEST_USER and password == TEST_PASSWORD:
            self.authenticated = True
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class LocalSFTPServer(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(root).resolve()

    def _resolve(self, path):
        candidate = (self.root / path.lstrip("/")).resolve()
        if candidate != self.root and self.root not in candidate.parents:
            raise OSError(errno.EACCES, "path escapes test root")
        return candidate

    def canonicalize(self, path):
        return "/" + str(Path(path).as_posix()).lstrip("/")

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._resolve(path).stat())
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._resolve(path).lstat())
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    def open(self, path, flags, attr):
        try:
            target = self._resolve(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            mode = getattr(attr, "st_mode", None) or 0o644
            descriptor = os.open(target, flags, mode)
            if flags & os.O_RDWR:
                stream_mode = "r+b"
            elif flags & os.O_WRONLY:
                stream_mode = "wb"
            else:
                stream_mode = "rb"
            stream = os.fdopen(descriptor, stream_mode)
            handle = paramiko.SFTPHandle(flags)
            if flags & os.O_WRONLY or flags & os.O_RDWR:
                handle.writefile = stream
            if not flags & os.O_WRONLY or flags & os.O_RDWR:
                handle.readfile = stream
            return handle
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    def chattr(self, path, attr):
        try:
            paramiko.SFTPServer.set_file_attr(str(self._resolve(path)), attr)
            return paramiko.SFTP_OK
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)


def run_sftp(control_socket, port, destination, batch):
    result = subprocess.run(
        [
            "/usr/bin/sftp",
            "-b",
            "-",
            "-P",
            str(port),
            "-o",
            f"ControlPath={control_socket}",
            "-o",
            "ControlMaster=no",
            "-o",
            "BatchMode=yes",
            "--",
            destination,
        ],
        input=(batch + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=12,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr + result.stdout).decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"SFTP failed with status {result.returncode}: {detail}")


def main():
    host_key = paramiko.RSAKey.generate(2048)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    port = listener.getsockname()[1]

    project_root = Path(__file__).resolve().parent.parent
    askpass_helper = project_root / "Packaging" / "SHXAskPass"
    server_error = []

    with tempfile.TemporaryDirectory(prefix="ks-sftp-", dir="/tmp") as directory:
        temporary = Path(directory)
        remote_root = temporary / "remote"
        remote_root.mkdir()
        (remote_root / "preview.txt").write_text("from-server\n", encoding="utf-8")

        def serve():
            transport = None
            try:
                client, _ = listener.accept()
                transport = paramiko.Transport(client)
                transport.add_server_key(host_key)
                transport.set_subsystem_handler(
                    "sftp",
                    paramiko.SFTPServer,
                    LocalSFTPServer,
                    root=remote_root,
                )
                transport.start_server(server=PasswordServer())
                channels = []
                while transport.is_active():
                    channel = transport.accept(0.5)
                    if channel is not None:
                        channels.append(channel)
            except Exception as exc:
                server_error.append(str(exc))
            finally:
                if transport is not None:
                    transport.close()
                listener.close()

        server_thread = threading.Thread(target=serve, daemon=True)
        server_thread.start()

        askpass_socket = temporary / "askpass.sock"
        known_hosts = temporary / "known_hosts"
        control_socket = temporary / "control.sock"
        broker = subprocess.Popen(
            ["/usr/bin/nc", "-lU", str(askpass_socket)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert broker.stdin is not None
        broker.stdin.write(TEST_PASSWORD + "\n")
        broker.stdin.close()

        environment = os.environ.copy()
        environment.update(
            {
                "SSH_ASKPASS": str(askpass_helper),
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "KiteShell",
                "SHX_ASKPASS_SOCKET": str(askpass_socket),
            }
        )
        destination = f"{TEST_USER}@127.0.0.1"
        master = subprocess.Popen(
            [
                "/usr/bin/ssh",
                "-MN",
                "-p",
                str(port),
                "-o",
                "ConnectTimeout=5",
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                f"UserKnownHostsFile={known_hosts}",
                "-o",
                "PreferredAuthentications=password",
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "NumberOfPasswordPrompts=1",
                "-o",
                "ControlMaster=yes",
                "-o",
                f"ControlPath={control_socket}",
                "-o",
                "ControlPersist=no",
                "--",
                destination,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

        deadline = time.monotonic() + 8
        while not control_socket.exists() and master.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        if not control_socket.exists():
            detail = master.stderr.read().decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"SSH ControlMaster did not start: {detail}")

        local_copy = temporary / "local-preview.txt"
        run_sftp(control_socket, port, destination, f'get -p "/preview.txt" "{local_copy}"')
        if local_copy.read_text(encoding="utf-8") != "from-server\n":
            raise RuntimeError("downloaded preview did not match server content")

        local_copy.write_text("edited-locally\n", encoding="utf-8")
        run_sftp(control_socket, port, destination, f'put -p "{local_copy}" "/preview.txt"')
        if (remote_root / "preview.txt").read_text(encoding="utf-8") != "edited-locally\n":
            raise RuntimeError("edited local file was not uploaded back to the server")

        subprocess.run(
            ["/usr/bin/ssh", "-S", str(control_socket), "-O", "exit", destination],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        master.wait(timeout=5)
        if broker.poll() is None:
            broker.terminate()
            broker.wait(timeout=2)
        server_thread.join(timeout=5)
        if server_error:
            raise RuntimeError(server_error[0])

    print("KiteShell SFTP edit integration test: passed")


if __name__ == "__main__":
    main()
