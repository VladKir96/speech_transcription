from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


class DraftPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        for name in release.ASSETS:
            (self.folder / name).write_text(name)
        (self.folder / "LocalCaption.md").write_text("Local release notes")
        self.metadata = {"version": "1.5.0", "repository": "example/caption", "source": "base"}
        self.assets = {}
        self.uploads = []
        self.fail_upload = None
        self.corrupt_download = None
        self.published = False

    def view(self, repo, tag):
        return json.loads(json.dumps({
            "isDraft": not self.published, "url": "https://example.com/release",
            "assets": list(self.assets.values()),
        }))

    def command(self, *args, **kwargs):
        self.assertEqual(args[:2], ("gh", "release"))
        if args[2] == "upload":
            path = args[4]
            self.uploads.append(path.name)
            if self.fail_upload == path.name:
                raise subprocess.CalledProcessError(1, args)
            self.assets[path.name] = {
                "name": path.name, "state": "uploaded", "size": path.stat().st_size,
                "digest": f"sha256:{release.digest(path)}",
            }
        elif args[2] == "download":
            for name in self.assets:
                destination = Path(args[args.index("--dir") + 1]) / name
                shutil.copyfile(self.folder / name, destination)
                if name == self.corrupt_download:
                    destination.write_bytes(b"bad download")
        elif args[2] == "edit":
            self.assertEqual(set(self.assets), set(release.ASSETS))
            self.published = True
        else:
            self.fail(f"Unexpected command: {args}")

    def publish(self):
        with patch.object(release, "release_view", self.view), \
             patch.object(release, "release_commit", return_value="bump"), \
             patch.object(release, "remote_refs", return_value={"refs/heads/main": "bump"}), \
             patch.object(release, "run", self.command), \
             patch.object(release, "verify_public") as verify, redirect_stdout(StringIO()):
            release.publish(self.folder, self.metadata, b"info", "main", {"refs/tags/v1.5.0": "bump"})
            verify.assert_called_once_with(self.folder, "example/caption", "v1.5.0")

    def test_failed_upload_can_resume_without_overwriting_assets(self):
        self.fail_upload = "LocalCaption.zip"
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertFalse(self.published)
        self.assertEqual(set(self.assets), {"LocalCaption.dmg"})

        self.fail_upload = None
        self.publish()
        self.assertTrue(self.published)
        self.assertEqual(self.uploads.count("LocalCaption.dmg"), 1)

    def test_corrupt_download_leaves_release_in_draft(self):
        self.corrupt_download = "appcast.xml"
        with self.assertRaisesRegex(release.ReleaseError, "Draft asset differs: appcast.xml"):
            self.publish()
        self.assertFalse(self.published)


if __name__ == "__main__":
    unittest.main()
