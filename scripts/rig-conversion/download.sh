#!/bin/sh
# Downloads IEMs measured on both a B&K 5128 (Earphones Archive) and an IEC 711 coupler
# (Super* Review), for computing the rig conversion. Usage: download.sh <empty work directory>
set -e
WORK="$1"
mkdir -p "$WORK/m5128" "$WORK/m711"
cd "$WORK"
curl -sSL -o book5128.json https://earphonesarchive.squig.link/data/phone_book.json
curl -sSL -o book711.json https://squig.link/data/phone_book.json

python3 -I - <<'PY'
import json, re
def entries(path):
    out = {}
    for brand in json.load(open(path)):
        for phone in brand.get('phones', []):
            name = phone.get('name') if isinstance(phone, dict) else phone
            files = phone.get('file') if isinstance(phone, dict) else phone
            if isinstance(files, list):
                files = files[0]
            out[re.sub(r'[^a-z0-9]', '', f"{brand.get('name')}{name}".lower())] = (f"{brand.get('name')} {name}", files)
    return out
a, b = entries('book5128.json'), entries('book711.json')
with open('pairs.tsv', 'w') as fh:
    for key in sorted(set(a) & set(b)):
        fh.write(f"{a[key][0]}\t{a[key][1]}\t{b[key][1]}\n")
PY

enc() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
while IFS="$(printf '\t')" read -r label f5128 f711; do
  for ch in L R; do
    curl -sSf -o "m5128/$label $ch.txt" "https://earphonesarchive.squig.link/data/$(enc "$f5128 $ch.txt")" || rm -f "m5128/$label $ch.txt"
    curl -sSf -o "m711/$label $ch.txt" "https://squig.link/data/$(enc "$f711 $ch.txt")" || rm -f "m711/$label $ch.txt"
  done
done < pairs.tsv
echo "$(wc -l < pairs.tsv) IEMs in both databases"
