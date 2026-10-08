#!/bin/sh
# Start the matrix test's git server: HTTPS (githttpd), SSH (sshd) and an HTTP
# proxy (tinyproxy), all serving the same repositories. githttpd is also the
# Git LFS server; over SSH, git-lfs-authenticate sends git-lfs to it.
#
# Everything a client needs is written to /export, then /ready is created:
#   ca.crt, ca.hash     private CA that signed the HTTPS certificate, and its
#                       OpenSSL subject hash (for an SSL_CERT_DIR)
#   id_ed25519          client key accepted by sshd for user git
#   known_hosts         sshd's host key for "gitserver"
#   main.sha, pr.sha    tip of main, and of refs/pull/1/head (not on a branch)
#
# The HTTPS certificate is valid for "gitserver" and "git.internal". Only this
# container resolves git.internal, so a client can reach it only through the
# proxy.
set -eu

mkdir -p /etc/gitserver /export
cd /etc/gitserver

# Private CA and server certificate.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
	-subj "/CN=static-git test CA" -keyout ca.key -out ca.crt 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
	-subj "/CN=gitserver" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:gitserver,DNS:git.internal\nextendedKeyUsage=serverAuth\n' >ext.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 \
	-extfile ext.cnf -out server.crt 2>/dev/null
cp ca.crt /export/ca.crt
openssl x509 -noout -subject_hash -in ca.crt >/export/ca.hash
echo "127.0.0.1 git.internal" >>/etc/hosts

# SSH: user git, one ed25519 client key.
ssh-keygen -A >/dev/null
adduser -D -s /bin/sh git
echo "git:*" | chpasswd -e >/dev/null 2>&1
mkdir -p ~git/.ssh
ssh-keygen -q -t ed25519 -N "" -C client -f /export/id_ed25519
cp /export/id_ed25519.pub ~git/.ssh/authorized_keys
echo "gitserver $(cut -d' ' -f1-2 /etc/ssh/ssh_host_ed25519_key.pub)" >/export/known_hosts

# Over SSH, git-lfs asks git-lfs-authenticate where the LFS server is, then
# uses that HTTPS URL with the credentials it returns, as on GitHub. The SSH
# path /srv/git/<repo> is /auth/<repo> over HTTPS.
token=$(printf '%s:%s' "$AUTH_USER" "$AUTH_PASS" | base64)
cat >/usr/local/bin/git-lfs-authenticate <<EOF
#!/bin/sh
printf '{"href":"https://gitserver/auth/%s/info/lfs","header":{"Authorization":"Basic $token"}}\n' "\${1#/srv/git/}"
EOF
chmod 755 /usr/local/bin/git-lfs-authenticate

# Repositories. main has a submodule with a relative URL, so the same repo
# works over HTTPS, authenticated HTTPS and SSH. lfs.dat is in Git LFS: the
# commit has its pointer file and /srv/lfs has its content, so making it needs
# no git-lfs.
git config --system safe.directory '*'
git config --system init.defaultBranch main
git config --system user.name "Test"
git config --system user.email "test@example.com"
git config --system protocol.file.allow always

work=$(mktemp -d)
git init -q "$work/sub"
echo sub >"$work/sub/sub.txt"
git -C "$work/sub" add . && git -C "$work/sub" commit -q -m "sub: first"

git init -q "$work/main"
cd "$work/main"
echo hello >README
mkdir -p src docs
echo 'int main(void) { return 0; }' >src/main.c
echo docs >docs/index.md
echo unicode >"ünïcödé.txt"
echo "stored in git lfs" >"$work/lfs.dat"
oid=$(sha256sum "$work/lfs.dat" | cut -d' ' -f1)
mkdir -p /srv/lfs
cp "$work/lfs.dat" "/srv/lfs/$oid"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' \
	"$oid" "$(wc -c <"$work/lfs.dat")" >lfs.dat
echo '*.dat filter=lfs diff=lfs merge=lfs -text' >.gitattributes
git add . && git commit -q -m "Grüße 🌍: first commit"
git tag -a v1 -m v1
git submodule -q add "$work/sub" sub
git config -f .gitmodules submodule.sub.url ../sub.git
git add .gitmodules && git commit -q -m "Add submodule"
echo two >>README && git commit -q -am "Second commit"
git checkout -q -b pr
echo pr >pr.txt && git add pr.txt && git commit -q -m "PR commit"
git checkout -q main

mkdir -p /srv/git
git clone -q --bare "$work/sub" /srv/git/sub.git
git clone -q --bare "$work/main" /srv/git/main.git
git -C /srv/git/main.git update-ref refs/pull/1/head "$(git rev-parse pr)"
git -C /srv/git/main.git branch -q -D pr
git rev-parse main >/export/main.sha
git rev-parse pr >/export/pr.sha
for r in /srv/git/*.git; do
	git -C "$r" config http.receivepack true
	git -C "$r" config uploadpack.allowAnySHA1InWant true
	git -C "$r" config uploadpack.allowFilter true
done
chown -R git:git /srv/git /srv/lfs ~git /etc/gitserver
chmod 700 ~git/.ssh

cat >/etc/tinyproxy.conf <<'EOF'
Port 8888
Listen 0.0.0.0
Timeout 60
LogFile "/var/log/tinyproxy.log"
LogLevel Connect
EOF
touch /var/log/tinyproxy.log

/usr/sbin/sshd -e
tinyproxy -c /etc/tinyproxy.conf
touch /ready
# As git, like sshd's sessions, so pushes over either protocol can write to
# the repositories. Docker lets any user bind port 443 in a container.
exec su git -s /usr/local/bin/githttpd
