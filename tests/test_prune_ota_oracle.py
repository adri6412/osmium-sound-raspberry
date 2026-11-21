#!/usr/bin/env python3
"""prune-ota-oracle.py: only the newest release of each channel stays on Oracle.

The Raspberry twin of test_prune_ota_r2.py. A fake bucket, no network. What
matters: a release a device may still be told to download is never deleted —
the one its channel manifest names, the one being published, one another run is
uploading right now — and nothing is deleted at all when a channel's manifest is
unknown. The Pi differences pinned here: the prefix is ``ota-rpi/``, the tags
carry no leading ``v``, and the manifests live in the bucket itself (no Pages).
"""
import datetime
import importlib.util
import io
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    'prune_oracle', os.path.join(HERE, '..', '.github', 'scripts', 'prune-ota-oracle.py'))
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)

NOW = datetime.datetime(2026, 11, 21, 12, 0, tzinfo=datetime.timezone.utc)
OLD = NOW - datetime.timedelta(days=5)
FILES = ('osmium-rpi-{t}.raucb', 'osmium-rpi-{t}.raucb.sha256')


class NoSuchKey(Exception):
    pass


class FakeS3:
    def __init__(self, tags, mirrors, recent=()):
        self.objects = {}
        for t in tags:
            for f in FILES:
                self.objects[f'ota-rpi/{t}/{f.format(t=t)}'] = \
                    NOW - datetime.timedelta(minutes=10) if t in recent else OLD
        for ch, t in mirrors.items():
            self.objects[f'ota-rpi/latest-{ch}.json'] = OLD
        self.mirrors = mirrors
        self.deleted = []

    def get_object(self, Bucket, Key):
        ch = Key[len('ota-rpi/latest-'):-len('.json')]
        if ch not in self.mirrors:
            raise NoSuchKey('NoSuchKey')
        return {'Body': io.BytesIO(json.dumps({'tag_name': self.mirrors[ch]}).encode())}

    def get_paginator(self, _):
        fake = self

        class P:
            def paginate(self, Bucket, Prefix):
                yield {'Contents': [{'Key': k, 'LastModified': m}
                                    for k, m in sorted(fake.objects.items()) if k.startswith(Prefix)]}
        return P()

    def delete_objects(self, Bucket, Delete):
        for o in Delete['Objects']:
            self.deleted.append(o['Key'])
            del self.objects[o['Key']]
        return {}

    def tags(self):
        return sorted({k.split('/')[1] for k in self.objects
                       if k.startswith('ota-rpi/') and k.count('/') == 2
                       and not k.split('/')[1].startswith('latest-')})


def run(s3, *argv):
    os.environ.pop('GITHUB_STEP_SUMMARY', None)
    return prune.main(list(argv), s3=s3, now=NOW)


class Prune(unittest.TestCase):
    def test_keeps_the_newest_of_each_channel_only(self):
        s3 = FakeS3(['2.5.26', '2.5.26-dev.6', '2.5.26-dev.6-alpha12',
                     '2.5.26-dev.6-alpha13'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6',
                     'alpha': '2.5.26-dev.6-alpha13'})
        self.assertEqual(run(s3), 0)
        self.assertEqual(s3.tags(), ['2.5.26', '2.5.26-dev.6', '2.5.26-dev.6-alpha13'])
        self.assertIn('ota-rpi/latest-prod.json', s3.objects)  # manifests untouched

    def test_the_release_being_published_stays(self):
        s3 = FakeS3(['2.5.26-dev.6-alpha13', '2.5.26-dev.6-alpha14'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6',
                     'alpha': '2.5.26-dev.6-alpha13'})
        # alpha14 is being published; its manifest is not updated yet.
        run(s3, '--keep', '2.5.26-dev.6-alpha14', '--grace-hours', '0')
        self.assertIn('2.5.26-dev.6-alpha14', s3.tags())

    def test_an_upload_in_progress_is_left_alone(self):
        s3 = FakeS3(['2.5.26-dev.6-alpha13', '2.5.26-dev.6-alpha14'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6',
                     'alpha': '2.5.26-dev.6-alpha13'},
                    recent=['2.5.26-dev.6-alpha14'])
        run(s3)
        self.assertIn('2.5.26-dev.6-alpha14', s3.tags())   # within grace
        run(s3, '--grace-hours', '0')
        self.assertNotIn('2.5.26-dev.6-alpha14', s3.tags())

    def test_an_unknown_channel_deletes_nothing(self):
        s3 = FakeS3(['2.5.26', '2.5.26-dev.6'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6'})  # no alpha manifest
        self.assertEqual(run(s3), 0)
        self.assertEqual(s3.deleted, [])

    def test_dry_run_deletes_nothing(self):
        s3 = FakeS3(['2.5.26-dev.6-alpha12', '2.5.26-dev.6-alpha13'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6',
                     'alpha': '2.5.26-dev.6-alpha13'})
        run(s3, '--dry-run')
        self.assertEqual(s3.deleted, [])

    def test_only_release_folders_are_considered(self):
        s3 = FakeS3(['2.5.26-dev.6-alpha12', '2.5.26-dev.6-alpha13'],
                    {'prod': '2.5.26', 'dev': '2.5.26-dev.6',
                     'alpha': '2.5.26-dev.6-alpha13'})
        s3.objects['ota-rpi/ci-test/x'] = OLD
        run(s3)
        self.assertIn('ota-rpi/ci-test/x', s3.objects)          # non-tag folder kept
        self.assertNotIn('2.5.26-dev.6-alpha12', s3.tags())     # old alpha pruned


if __name__ == '__main__':
    unittest.main()
