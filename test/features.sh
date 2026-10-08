#!/bin/sh
# Exercise git features that depend on how the bundle was built (PCRE2,
# iconv, zlib, hooks and editors through sh, helper programs in
# libexec/git-core, git-lfs's filters), inside a test image. POSIX sh.
set -eu

check() {
	echo "  $1"
}

export GIT_TERMINAL_PROMPT=0
export HOME="${HOME:-/root}"
root=$(mktemp -d)
cd "$root"

git config --global user.name "Test"
git config --global user.email "test@example.com"
git config --global init.defaultBranch main
test "$(git config --global user.name)" = Test
check "global config in \$HOME"

git init -q repo
cd repo
printf 'hello wörld\nfoo123\n' >a.txt
git add a.txt

# Hooks run through sh.
printf '#!/bin/sh\necho ran >"%s/hook.log"\n' "$root" >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
git commit -q -m "café"
grep -qx ran "$root/hook.log"
check "pre-commit hook"

git grep -qP 'foo\d+'
check "git grep -P (PCRE2)"

git log -G'wörld' --format=%s | grep -qx "café"
check "git log -G with UTF-8"

# Re-encode the UTF-8 message to Latin-1 through iconv: é is byte 0xe9.
test "$(git log -1 --encoding=ISO-8859-1 --format=%s | od -An -tx1 | tr -d ' \n')" = 636166e90a
check "iconv re-encoding"

echo two >b.txt && git add b.txt && git commit -q -m two
git tag -a v1 -m v1
test "$(git describe)" = v1
check "annotated tag, describe"

git archive --format=tar.gz -o "$root/a.tgz" HEAD
tar -tzf "$root/a.tgz" | grep -qx a.txt
check "archive --format=tar.gz"

git worktree add -q "$root/wt" -b wt
test -f "$root/wt/a.txt"
git worktree remove "$root/wt"
check "worktree add/remove"

git bundle create -q "$root/r.bundle" --all
git clone -q "$root/r.bundle" "$root/from-bundle"
check "bundle create, clone from bundle"

# --no-local runs upload-pack and index-pack, as a network clone does.
git clone -q --no-local . "$root/no-local"
test "$(git -C "$root/no-local" rev-parse HEAD)" = "$(git rev-parse HEAD)"
check "clone --no-local"

git gc -q
git fsck --no-progress --strict
git commit-graph verify
check "gc, fsck, commit-graph"

git format-patch -q -1 -o "$root/patches"
git checkout -q -b am HEAD~1
git am -q "$root"/patches/*.patch
test -f b.txt
git checkout -q main
check "format-patch, am"

GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true git rebase -q -i --root
check "rebase -i (sequence editor through sh)"

echo three >d.txt && git add d.txt && git commit -q -m three
git bisect start HEAD HEAD~2 >/dev/null
git bisect run sh -c 'test ! -f b.txt' | grep -q "is the first bad commit"
git bisect reset >/dev/null 2>&1
check "bisect run"

echo stash >c.txt && git stash push -q -u && git stash pop -q >/dev/null && test -f c.txt
check "stash"

sock="$root/cred.sock"
printf 'protocol=https\nhost=example.com\nusername=u\npassword=p\n\n' |
	git credential-cache --socket "$sock" store
printf 'protocol=https\nhost=example.com\n\n' |
	git credential-cache --socket "$sock" get | grep -qx password=p
git credential-cache --socket "$sock" exit
check "credential-cache daemon"

printf 'protocol=https\nhost=example.com\nusername=u\npassword=p\n\n' |
	git -c credential.helper="store --file=$root/creds" credential approve
grep -q 'https://u:p@example.com' "$root/creds"
check "credential-store"

git help -a >/dev/null
check "help -a"

# Git LFS with no server: the clean filter stores a pointer in git and the
# content in .git/lfs, and the smudge filter (filter-process) restores it.
git lfs install --local >/dev/null
git lfs track '*.bin' >/dev/null
echo "large file" >big.bin
git add .gitattributes big.bin
git cat-file -p :big.bin | grep -q "^version https://git-lfs.github.com/spec/v1"
git commit -q -m lfs
git lfs ls-files | grep -q " big.bin$"
rm big.bin
git checkout -- big.bin
grep -qx "large file" big.bin
test -z "$(git status --porcelain -- big.bin)"
git lfs fsck >/dev/null
check "git lfs track, clean and smudge filters, fsck"

cd /
rm -rf "$root"
