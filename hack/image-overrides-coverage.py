"""Find image references a chart renders that the image override table misses.

hack/image-list.sh --coverage renders each chart twice, once as it is and once
with a table that renames every image it found, and calls this for the steps
it cannot do in shell:

  refs <render.yaml>
      every string of the render that looks like an image reference, inside
      multi-line strings too, one per line
  table <names>
      the table renaming each image name of the file to coverage.invalid/<name>,
      as JSON
  leftovers <render.yaml> <names> <refs> <chart> <allowlist> <used>
      every place the render still names one of the images outside a
      containers[] or initContainers[] image, which the post-renderer rewrites
      and `helm template` does not run, followed by the references in <refs>
      that a chart-specific extractor read out of the render; one line each
      as <object> <path> <reference>, unless an allowlist line
      `<chart> <image name pattern> <Kind/name or *>` covers it, which is
      then appended to <used>
  unused <allowlist> <used>
      the allowlist lines nothing matched: an entry for a reference that now
      follows the table, or moved, would hide the next one under its name

Run with python3 -I.
"""
import fnmatch
import json
import re
import sys

import yaml

SENTINEL = "coverage.invalid"

COMP = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
HOST = r"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+(?::[0-9]+)?|localhost(?::[0-9]+)?)"
REF = re.compile(
    rf"^(?P<name>(?:{HOST}/)?{COMP}(?:/{COMP})*)"
    r"(?::(?P<tag>[A-Za-z0-9_][A-Za-z0-9._-]{0,127}))?"
    r"(?:@(?P<digest>sha256:[0-9a-f]{64}))?$")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/:@-]*[A-Za-z0-9]")
IMAGE_KEY = re.compile(r"(?i)image|repository")


def classify(value, key):
    """The reference value is, when it looks like one; None otherwise."""
    m = REF.match(value)
    if not m or value.startswith(("http", "/")):
        return None
    versioned = m.group("tag") or m.group("digest")
    if key and IMAGE_KEY.search(key) and versioned:
        return value
    # Elsewhere a registry path with a version, which rules out hostnames,
    # host:port, URLs and key:value strings.
    if versioned and "/" in m.group("name"):
        return value
    return None


def name_of(ref):
    """sigs.k8s.io/kustomize/api/internal/image.Split, name only."""
    slash = ref.find("/")
    head, rest = (ref[:slash], ref[slash:]) if slash > 0 else ("", ref)
    for sep in "@:":
        i = rest.find(sep)
        if i >= 0:
            rest = rest[:i]
    return head + rest


def strings(node, path=""):
    """(path, key, value) of every string scalar, and of every token of a
    multi-line one."""
    if isinstance(node, dict):
        if "name" in node and isinstance(node.get("value"), str):
            # The name of an env var says whether its value is an image; the
            # value itself is walked below under its own path.
            yield None, str(node["name"]), node["value"]
        for k, v in node.items():
            yield from strings(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, f"{path}[{i}]")
    elif isinstance(node, str):
        key = path.rsplit(".", 1)[-1]
        if "\n" in node:
            for tok in TOKEN.findall(node):
                yield path, None, tok
        else:
            yield path, key, node
            if node.startswith("--") and "=" in node:
                flag, _, val = node.partition("=")
                yield path, flag, val


def docs(path):
    for doc in yaml.safe_load_all(open(path)):
        if isinstance(doc, dict) and doc.get("kind") != "CustomResourceDefinition":
            meta = doc.get("metadata") or {}
            yield f"{doc.get('kind')}/{meta.get('name')}", doc


CONTAINER_IMAGE = re.compile(r"\.(containers|initContainers)\[[0-9]+\]\.image$")


def cmd_refs(render):
    found = set()
    for _, doc in docs(render):
        for path, key, value in strings(doc):
            r = classify(value, key)
            if r:
                found.add(r)
    for r in sorted(found):
        print(r)


def cmd_table(names):
    table = [{"name": n, "newName": f"{SENTINEL}/{n}"}
             for n in sorted(set(open(names).read().split()))]
    print(json.dumps(table))


def mention(name):
    # A name with a path is matched whole, with or without a version; a short
    # Docker Hub name only with one, or every word "redis" would count.
    tail = r"(?=[:@]|$|[\s\"',;)])" if "/" in name else r"(?=:[A-Za-z0-9_]|@sha256:)"
    return re.compile(r"(?<![A-Za-z0-9._/-])" + re.escape(name) + tail)


def cmd_leftovers(render, names_file, refs_file, chart, allowlist_file, used_file):
    names = sorted(set(open(names_file).read().split()))
    rules = []
    for line in open(allowlist_file):
        fields = line.split("#", 1)[0].split()
        if fields:
            if len(fields) != 3:
                sys.exit(f"{allowlist_file}: want <chart> <image> <object>: {line.strip()}")
            rules.append(fields)

    used = open(used_file, "a")

    def allowed(name, obj):
        for rule in rules:
            c, n, o = rule
            if c == chart and fnmatch.fnmatchcase(name, n) and o in (obj, "*"):
                print(" ".join(rule), file=used)
                return True
        return False

    patterns = [(n, mention(n)) for n in names]
    out = []
    for obj, doc in docs(render):
        for path, _, value in strings(doc):
            if path is None or CONTAINER_IMAGE.search(path) or value.startswith(SENTINEL + "/"):
                continue
            for n, p in patterns:
                if p.search(value) and not allowed(n, obj):
                    out.append(f"{obj}\t{path}\t{value if len(value) < 200 else n}")
    for ref in open(refs_file).read().split():
        n = name_of(ref)
        if n in names and not allowed(n, "(extracted)") and not ref.startswith(SENTINEL + "/"):
            out.append(f"(extracted)\t-\t{ref}")
    for line in sorted(set(out)):
        print(line)


def cmd_unused(allowlist_file, used_file):
    used = set(open(used_file).read().splitlines())
    for line in open(allowlist_file):
        fields = line.split("#", 1)[0].split()
        if fields and " ".join(fields) not in used:
            print(" ".join(fields))


def main():
    cmd, *args = sys.argv[1:]
    {"refs": cmd_refs, "table": cmd_table, "leftovers": cmd_leftovers, "unused": cmd_unused,
     "names": lambda f: [print(name_of(r)) for r in open(f).read().split()]}[cmd](*args)


main()
