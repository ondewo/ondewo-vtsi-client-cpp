#!/bin/sh
# Pins the release contract every ONDEWO VTSI client shares (see the Release chapter of the
# Makefile), so that a reordering cannot quietly bring back a release that pushes before it tests,
# tags before it has a valid token, or leaves the devops-accounts clone on disk:
#
#   STATIC  - parses the Makefile:
#     1. `release:` runs release_preflight -> codegen -> build_library -> the full test gate ->
#        git add -> guarded commit -> git push -> release branch -> tag -> GitHub release ->
#        release_verify, in that order, and release_verify is its last step;
#     2. the commit is `git diff --cached --quiet || git commit`, never a `-git commit` that
#        swallows a real failure;
#     3. release_preflight checks host tools, release notes, token validity and that the version
#        is unreleased; ondewo_release runs spc before anything is read;
#     4. no `gh auth login` and no bare host `gh` anywhere except upload_package (run by the
#        release workflow only), and `release` itself uploads nothing - the workflow is the single
#        uploader;
#     5. run_release_with_devops deletes its own clone before `$(MAKE) release` and has an EXIT
#        trap for the failure paths;
#     6. the proto compiler image carries a version tag and never sees the repository root as its
#        input volume;
#    10. every target is defined by exactly one `<target>:` line, and every recipe line that uses
#        GITHUB_GH_TOKEN first runs $(LOAD_RELEASE_CREDENTIALS), so release_preflight and
#        release_verify work STANDALONE with only DEVOPS_ACCOUNT_DIR set (the release driver);
#   BEHAVIOURAL - runs run_release_with_devops from a copy of the Makefile whose `release` is a
#     stub, with a fixture instead of the real devops-accounts repo:
#     7. the clone is gone BEFORE `release` starts, the token has arrived in its environment, and
#        nothing printed it;
#     8. the clone is gone after a failing release, a failing clone and a file without the token;
#     9. a caller's DEVOPS_ACCOUNT_DIR is used as-is and left in place;
#    11. standalone, check_release_credentials loads the token from DEVOPS_ACCOUNT_DIR without
#        printing it, and refuses without one; `make -n` of the devops step clones nothing.
#    12. `make release_verify VERIFY_ATTEMPTS=.. VERIFY_INTERVAL_S=..` hands both overrides into the
#        container that runs tools/verify_release_asset.sh (docker and git are stubbed on PATH).
#
# Registered with CTest by tests/CMakeLists.txt; run by hand as:
#   sh tests/test_release_order.sh <repository root>
set -eu

root="${1:-$(dirname "$0")/..}"
cd "$root"
root="$(pwd)"
[ -f Makefile ] || { echo "FAIL: no Makefile in $root" >&2; exit 1; }
failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# ----------------------------------------------------------------------------------------------
# STATIC
static_out="$(perl -e '
  use strict;
  use warnings;
  my @failures;
  sub fail { push @failures, join("", @_) }
  open(my $mk, "<", "Makefile") or die "Makefile: $!";
  my @raw = <$mk>;
  close $mk;

  # Recipes keyed by target, as logical lines (continuations joined, comments dropped).
  my (%recipe, %prereqs, $target);
  my $pending = "";
  for my $line (@raw) {
    chomp $line;
    if ($line =~ /^([A-Za-z0-9_.%\-]+)\s*:(?!=)(.*)$/) {
      my ($name, $rest) = ($1, $2);
      $target = $name;
      next if $rest =~ /^\s*export\s/;          # target-specific variable line
      $rest =~ s/##.*$//;
      $prereqs{$name} = [ split " ", $rest ];
      $recipe{$name} //= [];
      next;
    }
    next unless defined $target;
    if ($line =~ /^\t(.*)$/) {
      my $cmd = $pending . $1;
      if ($cmd =~ s/\\\s*$/ /) { $pending = $cmd; next; }
      $pending = "";
      $cmd =~ s/^\s+//;
      push @{ $recipe{$target} }, $cmd;
    } elsif ($line !~ /^#/) {
      undef $target unless $line =~ /^\s*$/;
    }
  }

  # 1. The order of `release`.
  my @rel = map { (my $c = $_) =~ s/^[-@+]+//; $c } @{ $recipe{release} || [] };
  fail("the release recipe is empty") unless @rel;
  my @steps = (
    [ "release_preflight", qr/^make release_preflight$/ ],
    [ "code generation",   qr/^make .*\bgenerate_ondewo_protos\b/ ],
    [ "build_library",     qr/^make \$\(call toolchain,build_library\)$/ ],
    [ "the full test gate", qr/^make \$\(call toolchain,test\)$/ ],
    [ "git add",           qr/^git add / ],
    [ "the guarded commit", qr/^git diff --cached --quiet \|\| git commit --no-verify -m / ],
    [ "git push",          qr/^git push$/ ],
    [ "create_release_branch", qr/^make create_release_branch$/ ],
    [ "create_release_tag", qr/^make create_release_tag$/ ],
    [ "build_gh_release",  qr/^make build_gh_release$/ ],
    [ "release_verify",    qr/^make release_verify$/ ],
  );
  my ($prev_name, $prev_at) = ("", -1);
  for my $step (@steps) {
    my ($name, $re) = @$step;
    my ($at) = grep { $rel[$_] =~ $re } 0 .. $#rel;
    if (!defined $at) { fail("release does not run $name"); next; }
    fail("release runs $name (step ", $at + 1, ") before $prev_name (step ", $prev_at + 1, ")")
      if $at < $prev_at;
    ($prev_name, $prev_at) = ($name, $at);
  }
  my @makes = grep { $rel[$_] =~ /^make / } 0 .. $#rel;
  fail("release_verify is not the last make step of release")
    unless @makes && $rel[$makes[-1]] eq "make release_verify";
  fail("release runs the test gate with a leading - (its failure would be ignored)")
    if grep { /^-\s*make \$\(call toolchain,test\)/ } @{ $recipe{release} || [] };

  # 2. No swallowed commit anywhere.
  for my $t (sort keys %recipe) {
    fail("$t: `-git commit` swallows a real commit failure")
      if grep { /^-\s*git commit/ } @{ $recipe{$t} };
  }

  # 3. Preflight and ondewo_release prerequisites.
  my %pre = map { $_ => 1 } @{ $prereqs{release_preflight} || [] };
  for my $need (qw(check_host_tools check_release_notes check_gh_token_valid check_version_unreleased)) {
    fail("release_preflight does not depend on $need") unless $pre{$need};
  }
  my @od = @{ $prereqs{ondewo_release} || [] };
  fail("ondewo_release must be `spc run_release_with_devops`, is: @od")
    unless "@od" eq "spc run_release_with_devops";

  # 4. gh only in the pinned image; no login; release uploads nothing itself.
  for my $t (sort keys %recipe) {
    for my $c (@{ $recipe{$t} }) {
      fail("$t: gh auth login stores the token on the host: $c") if $c =~ /gh auth login/;
      next if $t eq "upload_package";
      (my $code = $c) =~ s/"[^"]*"//g;            # message text may say "gh"
      fail("$t: a bare host gh call (use \$(GH_RUN) gh ...): $c")
        if $code =~ /(?:^|[\s;|&(])gh\s/ && $code !~ /\$\(GH_RUN\)\s+gh\s/;
      fail("$t: --clobber upload outside upload_package: $c") if $c =~ /--clobber/ && $c !~ /^\@?echo/;
    }
  }
  fail("release uploads the archive itself (the release workflow is the single uploader)")
    if grep { /upload_package|\bpublish\b(?!_dry_run)/ } @rel;

  # 5. The devops clone.
  my $devops = join("\n", @{ $recipe{run_release_with_devops} || [] });
  fail("run_release_with_devops has no recipe") unless length $devops;
  my $rm   = index($devops, q{rm -rf "$$owned"; });
  my $make = rindex($devops, q{$(MAKE) release});   # the last one; the first is the dry-run branch
  fail("run_release_with_devops does not delete its clone before \$(MAKE) release")
    unless $rm >= 0 && $make > $rm;
  fail("run_release_with_devops has no EXIT trap removing its clone")
    unless $devops =~ /trap \x27rm -rf "\$\$owned"\x27 EXIT/;
  fail("run_release_with_devops does not clone into a mktemp -d directory")
    unless $devops =~ /accounts="\$\$\(mktemp -d\)"/ && $devops =~ /\$\(DEVOPS_ACCOUNT_CLONE\) "\$\$accounts"/;

  # 6. The compiler image and its input volume.
  my ($image) = map { /^PROTO_COMPILER_IMAGE=(.*)$/ ? $1 : () } @raw;
  chomp($image) if defined $image;
  fail("PROTO_COMPILER_IMAGE carries no explicit tag: ", $image // "(unset)")
    unless defined $image && $image =~ /:\S/ && $image !~ /:latest$/;
  my $gen = join("\n", @{ $recipe{generate_ondewo_protos} || [] });
  fail("generate_ondewo_protos mounts the repository root as the input volume")
    if $gen =~ /(?:\$\(CURDIR\)|pwd\})"?:\/input-volume(?:[":\s]|$)/;

  # 10. One definition line per target; the token is loaded on every line that uses it.
  my %lines;
  for my $line (@raw) {
    $lines{$1}++ if $line =~ /^([A-Za-z0-9_.\-]+)\s*:(?!=)/;
  }
  for my $t (sort keys %lines) {
    fail("$t is defined on $lines{$t} lines - keep exactly one `$t:` line") if $lines{$t} > 1;
  }
  for my $t (sort keys %recipe) {
    next if $t eq "run_release_with_devops";      # reads the token itself, from its own clone
    for my $c (@{ $recipe{$t} }) {
      next unless $c =~ /\$\$\{?GITHUB_GH_TOKEN\b/;
      fail("$t: uses GITHUB_GH_TOKEN without loading it first (start the line with \$(LOAD_RELEASE_CREDENTIALS)): $c")
        unless $c =~ /^\@?\$\(LOAD_RELEASE_CREDENTIALS\);/;
    }
  }
  my ($ct) = join("\n", @raw) =~ /^CREDENTIAL_TARGETS=((?:[^\n]*\\\n)*[^\n]*)/m;
  my %ct = map { $_ => 1 } split /[\s\\]+/, ($ct // "");
  for my $need (qw(release release_preflight check_release_credentials release_verify build_gh_release)) {
    fail("CREDENTIAL_TARGETS does not export the token to $need") unless $ct{$need};
  }

  print STDERR "FAIL: $_\n" for @failures;
  print scalar(@failures), "\n";
')" || { echo "FAIL: the static Makefile parser crashed" >&2; exit 1; }
failures=$((failures + static_out))

# ----------------------------------------------------------------------------------------------
# BEHAVIOURAL
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT INT TERM
token="fixture-token-$$-value"
mkdir -p "$sandbox/repo" "$sandbox/tmp" "$sandbox/fixture" "$sandbox/fixture-without-token"
cp Makefile gh.Dockerfile "$sandbox/repo/"
printf 'GITHUB_GH_TOKEN=%s\n' "$token" > "$sandbox/fixture/account_github.env"
printf '# no token in here\nOTHER=1\n' > "$sandbox/fixture-without-token/account_github.env"
# A later recipe for the same target replaces the earlier one (make warns about it on stderr).
cat >> "$sandbox/repo/Makefile" <<'EOF'

release:
	@if [ -n "$$(ls -A "$$TMPDIR")" ]; then echo STUB_CLONE_STILL_PRESENT; else echo STUB_CLONE_GONE; fi
	@if [ "$$GITHUB_GH_TOKEN" = "$$EXPECTED_TOKEN" ]; then echo STUB_TOKEN_ARRIVED; else echo STUB_TOKEN_MISSING; fi
	@exit $(STUB_RELEASE_STATUS)
EOF

# run_devops <clone command> <release status> [DEVOPS_ACCOUNT_DIR] -> output in $out, status in $rc
run_devops() {
  rc=0
  out="$(cd "$sandbox/repo" && env -u DEVOPS_ACCOUNT_DIR -u GITHUB_GH_TOKEN ${3:+DEVOPS_ACCOUNT_DIR="$3"} \
    TMPDIR="$sandbox/tmp" EXPECTED_TOKEN="$token" \
    make --no-print-directory run_release_with_devops \
      DEVOPS_ACCOUNT_CLONE="$1" STUB_RELEASE_STATUS="$2" 2>&1)" || rc=$?
}
tmp_is_empty() { [ -z "$(ls -A "$sandbox/tmp")" ]; }
no_token_printed() {
  case "$out" in *"$token"*) fail "$1: the token was printed"; return ;; esac
}

# 7. success path
run_devops "cp -R $sandbox/fixture/." 0
[ "$rc" -eq 0 ] || fail "success path: run_release_with_devops failed ($rc): $out"
case "$out" in *STUB_CLONE_GONE*) ;; *) fail "success path: the clone still existed when release started: $out" ;; esac
case "$out" in *STUB_TOKEN_ARRIVED*) ;; *) fail "success path: release did not get GITHUB_GH_TOKEN: $out" ;; esac
tmp_is_empty || fail "success path: the clone is left on disk: $(ls -A "$sandbox/tmp")"
no_token_printed "success path"

# 8a. failing release
run_devops "cp -R $sandbox/fixture/." 1
[ "$rc" -ne 0 ] || fail "failing release: run_release_with_devops reported success"
tmp_is_empty || fail "failing release: the clone is left on disk"
no_token_printed "failing release"

# 8b. failing clone - the release must not start at all
run_devops "false" 0
[ "$rc" -ne 0 ] || fail "failing clone: run_release_with_devops reported success"
case "$out" in *STUB_*) fail "failing clone: release ran anyway: $out" ;; esac
tmp_is_empty || fail "failing clone: the clone directory is left on disk"

# 8c. account file without the token
run_devops "cp -R $sandbox/fixture-without-token/." 0
[ "$rc" -ne 0 ] || fail "no token: run_release_with_devops reported success"
case "$out" in *STUB_*) fail "no token: release ran anyway: $out" ;; esac
tmp_is_empty || fail "no token: the clone is left on disk"

# 9. the caller's clone
run_devops "false" 0 "$sandbox/fixture"
[ "$rc" -eq 0 ] || fail "DEVOPS_ACCOUNT_DIR: run_release_with_devops failed ($rc): $out"
case "$out" in *STUB_TOKEN_ARRIVED*) ;; *) fail "DEVOPS_ACCOUNT_DIR: release did not get the token: $out" ;; esac
[ -f "$sandbox/fixture/account_github.env" ] || fail "DEVOPS_ACCOUNT_DIR: the caller's clone was deleted"
tmp_is_empty || fail "DEVOPS_ACCOUNT_DIR: something was cloned although the caller supplied a clone"
no_token_printed "DEVOPS_ACCOUNT_DIR"

# 11. standalone credential loading, and a dry run that clones nothing
standalone() {
  rc=0
  out="$(cd "$sandbox/repo" && env -u DEVOPS_ACCOUNT_DIR -u GITHUB_GH_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
    ${1:+DEVOPS_ACCOUNT_DIR="$1"} make --no-print-directory check_release_credentials 2>&1)" || rc=$?
}
standalone "$sandbox/fixture"
[ "$rc" -eq 0 ] || fail "standalone: check_release_credentials did not load the token from DEVOPS_ACCOUNT_DIR: $out"
no_token_printed "standalone"
standalone "$sandbox/fixture-without-token"
[ "$rc" -ne 0 ] || fail "standalone: check_release_credentials passed with a DEVOPS_ACCOUNT_DIR that has no token"
standalone ""
[ "$rc" -ne 0 ] || fail "standalone: check_release_credentials passed without any credential"
rc=0
out="$(cd "$sandbox/repo" && env -u DEVOPS_ACCOUNT_DIR -u GITHUB_GH_TOKEN TMPDIR="$sandbox/tmp" \
  make -n --no-print-directory run_release_with_devops DEVOPS_ACCOUNT_CLONE="false" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "make -n run_release_with_devops failed ($rc) - did it try to clone?: $out"
case "$out" in *"dry run (make -n)"*) ;; *) fail "make -n run_release_with_devops did not take the dry-run path: $out" ;; esac
tmp_is_empty || fail "make -n run_release_with_devops created a clone directory"

# 12. command-line overrides of the verify wait reach the container. The docker stub prints, for
#     every `-e NAME` of a `docker run`, the value docker would copy into the container - but only
#     for VERIFY_*, never the token; the git stub answers `ls-remote` as if the tag existed.
mkdir -p "$sandbox/bin" "$sandbox/repo/tools"
cat > "$sandbox/bin/docker" <<'EOF'
#!/bin/sh
[ "$1" = "run" ] || exit 0
while [ $# -gt 0 ]; do
  if [ "$1" = "-e" ]; then
    case "$2" in
      VERIFY_*) eval "value=\${$2-unset}"; printf 'FORWARDED %s=[%s]\n' "$2" "$value" ;;
    esac
    shift
  fi
  shift
done
cat >/dev/null
EOF
printf '#!/bin/sh\nexit 0\n' > "$sandbox/bin/git"
chmod +x "$sandbox/bin/docker" "$sandbox/bin/git"
: > "$sandbox/repo/tools/verify_release_asset.sh"
rc=0
out="$(cd "$sandbox/repo" && env -u GITHUB_GH_TOKEN -u VERIFY_ATTEMPTS -u VERIFY_INTERVAL_S PATH="$sandbox/bin:$PATH" \
  DEVOPS_ACCOUNT_DIR="$sandbox/fixture" \
  make --no-print-directory release_verify VERIFY_ATTEMPTS=7 VERIFY_INTERVAL_S=4 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "release_verify with stubbed docker/git failed ($rc): $out"
case "$out" in *"FORWARDED VERIFY_ATTEMPTS=[7]"*) ;; *) fail "VERIFY_ATTEMPTS=7 on the command line does not reach the verify container: $out" ;; esac
case "$out" in *"FORWARDED VERIFY_INTERVAL_S=[4]"*) ;; *) fail "VERIFY_INTERVAL_S=4 on the command line does not reach the verify container: $out" ;; esac
no_token_printed "release_verify overrides"

[ "$failures" -eq 0 ] || { echo "${failures} release-order check(s) failed" >&2; exit 1; }
echo "release order OK: preflight -> build -> test -> commit -> push -> branch -> tag -> GitHub release -> verify; devops clone deleted before release and on every failure"
