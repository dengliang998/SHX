#!/usr/bin/env python3
"""Local, isolated password-authentication integration test for KiteShell."""

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
    def __init__(self, shell_requested: threading.Event):
        self.shell_requested = shell_requested
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

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        return True

    def check_channel_shell_request(self, channel):
        self.shell_requested.set()
        return True


def main():
    host_key = paramiko.RSAKey.generate(2048)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    port = listener.getsockname()[1]

    shell_requested = threading.Event()
    server = PasswordServer(shell_requested)
    server_error = []

    def serve():
        transport = None
        try:
            client, _ = listener.accept()
            transport = paramiko.Transport(client)
            transport.add_server_key(host_key)
            transport.start_server(server=server)
            channel = transport.accept(8)
            if channel is None or not shell_requested.wait(5):
                raise RuntimeError("SSH shell channel was not opened")
            channel.send(b"KiteShell integration test\r\n")
            channel.send_exit_status(0)
            time.sleep(0.1)
            channel.close()
        except Exception as exc:  # reported without credentials
            server_error.append(str(exc))
        finally:
            if transport is not None:
                transport.close()
            listener.close()

    server_thread = threading.Thread(target=serve, daemon=True)
    server_thread.start()

    project_root = Path(__file__).resolve().parent.parent
    askpass_helper = project_root / "Packaging" / "KiteShellAskPass"

    with tempfile.TemporaryDirectory(prefix="ks-ssh-", dir="/tmp") as directory:
        temporary = Path(directory)
        askpass_socket = temporary / "askpass.sock"
        sentinel = temporary / "connected"
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

        deadline = time.monotonic() + 2
        while not askpass_socket.exists() and time.monotonic() < deadline:
            time.sleep(0.01)

        environment = os.environ.copy()
        environment.update(
            {
                "SSH_ASKPASS": str(askpass_helper),
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "KiteShell",
                "KITESHELL_ASKPASS_SOCKET": str(askpass_socket),
            }
        )

        command = [
            "/usr/bin/ssh",
            "-tt",
            "-p",
            str(port),
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "PreferredAuthentications=password,keyboard-interactive",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "NumberOfPasswordPrompts=1",
            "-o",
            "PermitLocalCommand=yes",
            "-o",
            f"LocalCommand=/usr/bin/touch {sentinel}",
            "-o",
            "ControlMaster=yes",
            "-o",
            f"ControlPath={control_socket}",
            "-o",
            "ControlPersist=no",
            "--",
            f"{TEST_USER}@127.0.0.1",
        ]

        client = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=12,
            check=False,
        )
        server_thread.join(timeout=5)
        if broker.poll() is None:
            broker.terminate()
            broker.wait(timeout=2)

        if client.returncode != 0:
            detail = client.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"OpenSSH exited with status {client.returncode}: {detail}")
        if server_error:
            raise RuntimeError(server_error[0])
        if not server.authenticated:
            raise RuntimeError("The local SSH server did not accept the password")
        if not sentinel.exists():
            raise RuntimeError("The authenticated-connection sentinel was not created")

    print("KiteShell password SSH integration test: passed")


if __name__ == "__main__":
    main()
