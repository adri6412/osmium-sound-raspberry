#!/usr/bin/env python3
"""Keep only the newest OTA release of each channel on the Oracle OTA mirror.

Every Raspberry image, stable or not, is uploaded to the Oracle Object Storage
bucket (Milan, prefix ``ota-rpi/``) as ``ota-rpi/<tag>/<asset>`` and the per
channel manifests the devices read — ``ota-rpi/latest-<channel>.json`` — point
there (see build-rpi-image.yml). A device only ever installs the release its
channel's manifest names, so every ``ota-rpi/<tag>/`` folder that no channel
names any more is dead weight (a .raucb bundle is ~670 MB).

This is the Raspberry twin of prune-ota-r2.py: same logic, but the mirror is
Oracle (reached through its S3-compatible API with boto3), the prefix is
``ota-rpi/`` and the Pi tags carry no leading ``v`` (e.g. 2.5.26-dev.6-alpha14).
The authoritative "what each channel points at" is the manifest in the bucket
itself — the Pi has no gh-pages / Pages manifest.

Usage:
    prune-ota-oracle.py [--keep TAG ...] [--grace-hours N] [--dry-run]

What stays:
  * the tag named by each channel's manifest ``ota-rpi/latest-<channel>.json``;
  * every ``--keep`` tag (the release being published right now);
  * any folder written in the last ``--grace-hours`` hours: another channel may
    be uploading at this very moment and its manifest does not name it yet.

If a channel's manifest cannot be read, nothing is deleted: not knowing what a
channel points at is no reason to take its files away.

Environment: OCI_S3_ENDPOINT, OCI_S3_REGION, OCI_S3_BUCKET, OTA_PREFIX,
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
"""
import argparse
import datetime
import json
import os
import re
import sys

CHANNELS = ('prod', 'dev', 'alpha')
# Release tags only, WITHOUT a leading "v" (2.5.26, 2.5.26-dev.6-alpha14, …):
# the Raspberry fork tags and its ota-rpi/<tag>/ folders have no "v".
TAG_RE = re.compile(r'^\d+\.\d+\.\d+[0-9A-Za-z.-]*$')


def _prefix():
    p = os.environ.get('OTA_PREFIX', 'ota-rpi/')
    return p if p.endswith('/') else p + '/'


def group_by_tag(objects):
    """{tag: [objects]} for the keys shaped <prefix><tag>/<file>."""
    pfx = _prefix()
    out = {}
    for o in objects:
        rest = o['Key'][len(pfx):] if o['Key'].startswith(pfx) else ''
        parts = rest.split('/')
        if len(parts) >= 2 and TAG_RE.match(parts[0]) and parts[1]:
            out.setdefault(parts[0], []).append(o)
    return out


def plan(objects, keep, grace_hours, now):
    """(to delete {tag: [keys]}, kept-for-grace [tags]) for the listed objects."""
    delete, recent = {}, []
    limit = now - datetime.timedelta(hours=grace_hours)
    for tag, objs in sorted(group_by_tag(objects).items()):
        if tag in keep:
            continue
        if max(o['LastModified'] for o in objs) > limit:
            recent.append(tag)
            continue
        delete[tag] = [o['Key'] for o in objs]
    return delete, recent


def mirror_tags(s3, bucket):
    """{channel: tag} from the <prefix>latest-<channel>.json manifests."""
    pfx = _prefix()
    out = {}
    for ch in CHANNELS:
        try:
            body = s3.get_object(Bucket=bucket, Key=f'{pfx}latest-{ch}.json')['Body'].read()
            tag = json.loads(body).get('tag_name') or ''
        except Exception as e:  # missing manifest, or unreadable
            if 'NoSuchKey' not in repr(e) and '404' not in repr(e):
                raise
            continue
        if tag:
            out[ch] = tag
    return out


def list_ota(s3, bucket):
    objs = []
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=bucket, Prefix=_prefix()):
        objs.extend(page.get('Contents', []))
    return objs


def summary(lines):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')


def main(argv=None, s3=None, now=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--keep', action='append', default=[], metavar='TAG')
    ap.add_argument('--grace-hours', type=float, default=3)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)

    bucket = os.environ.get('OCI_S3_BUCKET', 'bucket-osmiumsound-raspberry')
    if s3 is None:
        import boto3
        from botocore.config import Config
        s3 = boto3.client(
            's3',
            endpoint_url=os.environ['OCI_S3_ENDPOINT'],
            region_name=os.environ.get('OCI_S3_REGION', 'eu-milan-1'),
            # Oracle's S3-compatible endpoint wants path-style addressing.
            config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}))
    now = now or datetime.datetime.now(datetime.timezone.utc)

    named = {ch: set() for ch in CHANNELS}
    for ch, tag in mirror_tags(s3, bucket).items():
        named[ch].add(tag)
    unknown = [ch for ch in CHANNELS if not named[ch]]
    if unknown:
        print(f"::warning::no manifest names a release for channel(s) {', '.join(unknown)}: "
              "nothing deleted")
        return 0

    keep = set(args.keep).union(*named.values())
    delete, recent = plan(list_ota(s3, bucket), keep, args.grace_hours, now)

    pfx = _prefix()
    lines = ['### OTA releases on the Oracle mirror (ota-rpi/)', '']
    for ch in CHANNELS:
        lines.append(f"- {ch}: {', '.join(sorted(named[ch]))}")
    for tag in recent:
        lines.append(f'- {tag}: written less than {args.grace_hours:g} h ago, left for the next run')
    verb = 'would delete' if args.dry_run else 'deleted'
    for tag, keys in delete.items():
        lines.append(f'- {tag}: {verb} ({len(keys)} files)')
        if args.dry_run:
            continue
        for i in range(0, len(keys), 1000):
            res = s3.delete_objects(Bucket=bucket, Delete={
                'Objects': [{'Key': k} for k in keys[i:i + 1000]], 'Quiet': True})
            if res.get('Errors'):
                print(f"::error::deleting {pfx}{tag}/ failed: {res['Errors'][:3]}")
                return 1
    if not delete:
        lines.append('- nothing to delete')
    print('\n'.join(lines))
    summary(lines)
    return 0


if __name__ == '__main__':
    sys.exit(main())
