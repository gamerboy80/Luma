#!/usr/bin/env python3
"""Reviewable coverage inventory; --reference verifies all upstream declaration keys.
No network access, source execution, or user data access. Generated Markdown stays in research/.
"""
import argparse, hashlib, json, pathlib, re
ROOT = pathlib.Path(__file__).resolve().parent.parent
INVENTORY = ROOT / 'research/SCENESCRIPT_API_COVERAGE.json'
MATRIX = ROOT / 'research/SCENESCRIPT_API_COVERAGE.md'

def declarations(source):
    clean = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    clean = re.sub(r'^\s*//.*', '', clean, flags=re.M)
    rows = []
    owner = None
    for line in clean.splitlines():
        line = line.strip()
        if not line: continue
        match = re.match(r"(?:declare )?(interface|class|module)\s+('?\w+'?)([^\{]*)\{", line)
        if match:
            owner = match[2].strip("'")
            rows.append({'api': owner, 'declaration': line.rstrip(' {'), 'kind': match[1]})
        elif line == '}': owner = None
        elif line.startswith('declare let '):
            name = re.match(r'declare let (\w+)',line)[1]
            rows.append({'api':'global.'+name, 'declaration':line,'kind':'global'})
        elif owner:
            match = re.match(r'(?:export |static |readonly )*(?:function |let )?(\w+)',line)
            if not match: raise ValueError('Unparsed declaration: '+line)
            name=match[1]; api=owner+'.'+name
            if any(row['api']==api for row in rows):
                api += '.overload'+str(sum(row['api'].startswith(api) for row in rows)+1)
            rows.append({'api':api,'declaration':line,'kind':'method' if '(' in line else 'property'})
    return rows

def markdown(data):
    counts={key:sum(row['status']==key for row in data['entries']) for key in ['implemented','unsupported','external provider']}
    out=['# SceneScript API coverage matrix','',
         'Source: [official reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference.html) and [official version 2.8 declarations](https://docs.wallpaperengine.io/reference/lib.sceneScript.d.ts), retrieved 2026-10-20.', '',
         'Pinned declaration: SCENESCRIPT_API_TYPES.d.ts. SHA-256: `'+data['referenceSHA256']+'`. All declarations, declared members, overloads, modules and globals have an individual row. Interface rows include inherited surfaces; `ILayer` combines those interfaces. Website-only aliases are listed at the end. Constructors are listed once with their declared union/optional arguments. The upstream file refers to undeclared `IModel`, `IAssetHandle` and `Any`; Luma does not invent an extra public API for those unresolved type names.','',
         f"{len(data['entries'])} entries: "+', '.join(f'{v} {k}' for k,v in counts.items())+'.','',
         '**Implemented** means the stated Luma scope, with the limits in each row; it is not a claim of full Wallpaper Engine fidelity. **External provider** means the type/event bridge exists but live data requires the named provider. **Unsupported** produces an error/diagnostic on use; no success-shaped dummy object is supplied. Event/data classes describe callback payloads, not ambient native constructors. See [compatibility and safeguards](SCENESCRIPT_COMPATIBILITY.md) for exact resource limits and verification scope.','',
         '## Code paths','',
         '- **Pure**: `text.js` / `scene-script-matrices.js`, inside SES; no host action.','- **Layer**: `scene-script-runtime.ts.snapshotLayer` → `scene-script-worker.ts.updateLayers` → `text.js` facade → layer patches → `applyPatches` / `applyStructuredChanges` → renderer.','- **Command**: worker command → generation/ID/type/range/path/size/rate checks in `applyCommands` → host renderer controller. Commands are asynchronous; mutations become visible on a later frame.','- **Event**: renderer/native provider → bounded worker event → compartment argument revival → callbacks → validated result/patches.','- **Storage/shared**: Worker-owned data; serialized shared data only crosses to the host. Functions never cross to the native app.','']
    group=None
    for row in data['entries']:
        owner=row['api'].split('.')[0]
        if owner!=group:
            group=owner;out += ['## '+owner,'','| API | Status | Bridge and limitation |','| --- | --- | --- |']
        out.append('| `'+row['api']+'` | '+row['status']+' | '+row['detail'].replace('|','/')+' |')
    return '\n'.join(out)+'\n'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--reference',type=pathlib.Path);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    data=json.loads(INVENTORY.read_text()); entries=data['entries']
    assert len({row['api'] for row in entries})==len(entries), 'Duplicate APIs'
    for row in entries:
        assert row['status'] in ['implemented','unsupported','external provider'] and len(row['detail'])>15, row
    if args.reference:
        source=args.reference.read_text()
        expected={row['api']:row['declaration'] for row in declarations(source)}
        actual={row['api']:row['declaration'] for row in entries if not row.get('websiteOnly')}
        assert expected==actual, 'Official declarations changed; review added/changed/removed APIs'
        assert hashlib.sha256(args.reference.read_bytes()).hexdigest()==data['referenceSHA256'], 'Reference changed'
    generated=markdown(data)
    if args.check: assert MATRIX.read_text()==generated, 'Coverage matrix is stale'
    else: MATRIX.write_text(generated)
    print(f'PASS: {len(entries)} individually classified SceneScript declarations and matrix synchronization')
if __name__=='__main__': main()
