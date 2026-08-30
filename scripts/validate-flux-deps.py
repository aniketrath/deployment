#!/usr/bin/env python3
"""
Validates the Flux Kustomization graph under clusters/:
  - every `dependsOn` name resolves to an object actually defined in clusters/
  - every `spec.path` exists on disk and is a valid kustomize-controller target
    (either it has a kustomization.yaml, or it's a non-empty directory of bare
    manifests, which Flux auto-generates a kustomization.yaml for on the fly)
"""
import glob
import os
import sys

import yaml

CLUSTERS_DIR = "clusters"


def load_docs(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def main():
    files = sorted(glob.glob(f"{CLUSTERS_DIR}/**/*.yaml", recursive=True))
    if not files:
        print(f"No manifests found under {CLUSTERS_DIR}/, skipping.")
        return 0

    kustomizations = {}  # name -> (source file, doc)
    all_names = set()
    errors = []

    for path in files:
        for doc in load_docs(path):
            kind = doc.get("kind")
            name = (doc.get("metadata") or {}).get("name")
            if not kind or not name:
                continue
            all_names.add(name)
            if kind == "Kustomization" and str(doc.get("apiVersion", "")).startswith(
                "kustomize.toolkit.fluxcd.io"
            ):
                kustomizations[name] = (path, doc)

    if not kustomizations:
        print(f"No Flux Kustomization objects found under {CLUSTERS_DIR}/, skipping.")
        return 0

    for name, (path, doc) in kustomizations.items():
        spec = doc.get("spec") or {}

        for dep in spec.get("dependsOn") or []:
            dep_name = dep.get("name") if isinstance(dep, dict) else dep
            if dep_name not in all_names:
                errors.append(
                    f"{path}: Kustomization '{name}' depends on '{dep_name}', "
                    f"which is not defined anywhere under {CLUSTERS_DIR}/"
                )

        kpath = spec.get("path")
        if kpath:
            norm = os.path.normpath(kpath)
            if not os.path.isdir(norm):
                errors.append(
                    f"{path}: Kustomization '{name}' points at path '{kpath}', "
                    f"which does not exist"
                )
            elif not os.path.isfile(os.path.join(norm, "kustomization.yaml")):
                # Flux's kustomize-controller auto-generates a kustomization.yaml
                # on the fly when a target path has none (a directory of bare
                # manifests, e.g. namespaces/) - that's valid, not an error.
                # Only flag it if the directory is genuinely empty.
                manifest_files = glob.glob(os.path.join(norm, "*.yaml")) + glob.glob(
                    os.path.join(norm, "*.yml")
                )
                if not manifest_files:
                    errors.append(
                        f"{path}: Kustomization '{name}' points at path '{kpath}', "
                        f"which has no kustomization.yaml and no manifests in it"
                    )

    if errors:
        print("Flux dependency graph validation FAILED:\n")
        for e in errors:
            print(f"  - {e}")
        print()
        return 1

    print(
        f"OK: {len(kustomizations)} Flux Kustomization(s) under {CLUSTERS_DIR}/ "
        f"have valid paths and dependsOn references."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())