#!/usr/bin/env bash

prune_installer_ui_tree() {
    local ui_root="$1"
    rm -rf \
        "${ui_root}/.git" \
        "${ui_root}/.github" \
        "${ui_root}/node_modules"
    find "${ui_root}" -type f \( \
        -name '.env' -o \
        -name '.env.*' -o \
        -name '*.map' -o \
        -name '*.test.*' -o \
        -name '*.spec.*' -o \
        -name 'package.json' -o \
        -name 'package-lock.json' -o \
        -name 'pnpm-lock.yaml' -o \
        -name 'yarn.lock' -o \
        -name 'tsconfig*.json' -o \
        -name 'vite.config.*' -o \
        -name 'tailwind.config.*' -o \
        -name 'README*' -o \
        -name 'LICENSE*' \
    \) -delete 2>/dev/null || true
}
