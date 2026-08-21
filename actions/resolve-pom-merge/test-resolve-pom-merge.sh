#!/usr/bin/env sh
# Tests for resolve-pom-merge.sh. Builds real git repos and real merge conflicts rather
# than mocking them, because the thing under test is git's conflict staging.
#
# usage: sh .github/scripts/test-resolve-pom-merge.sh
set -eu

SCRIPT=$(cd "$(dirname "$0")" && pwd)/resolve-pom-merge.sh
FAILURES=0

# pom <project-version> <extra-dependency-artifactId-or-empty> <logstash-version>
# Two independently editable regions — a property near the top and the tail of
# <dependencies> — so a test can change one side's pom without touching the other's.
pom() {
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.5</version>
    </parent>

    <groupId>com.rezatron</groupId>
    <artifactId>orders</artifactId>
    <version>$1</version>

    <properties>
        <java.version>21</java.version>
        <logstash.version>$3</logstash.version>
    </properties>

    <dependencies>
        <!-- a comment that must survive the merge -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>net.logstash.logback</groupId>
            <artifactId>logstash-logback-encoder</artifactId>
            <version>\${logstash.version}</version>
        </dependency>${2:+
        <dependency>
            <groupId>com.example</groupId>
            <artifactId>$2</artifactId>
        </dependency>}
    </dependencies>
</project>
XML
}

# setup <base-ver> <ours-ver> <ours-dep> <ours-logstash> <theirs-ver> <theirs-dep> <theirs-logstash>
# Leaves cwd in a repo mid-merge with pom.xml conflicted, mirroring the GitFlow back-merge:
# "ours" is develop, "theirs" is main.
setup() {
  D=$(mktemp -d); cd "$D"
  git init -q .; git config user.email t@t; git config user.name t
  pom "$1" "" 7.4 > pom.xml; git add pom.xml; git commit -qm base
  git branch theirs
  pom "$2" "$3" "$4" > pom.xml; git commit -qam ours
  git switch -q theirs
  pom "$5" "$6" "$7" > pom.xml; git commit -qam theirs
  git switch -q - >/dev/null 2>&1
  git merge --no-commit --no-ff theirs >/dev/null 2>&1 || true
}

check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; FAILURES=$((FAILURES+1)); fi; }
projver() { awk '/<\/parent>/{p=1} !d&&p&&/<version>/{gsub(/.*<version>|<\/version>.*/,"");print;d=1}' pom.xml; }

echo "the version-only conflict every release produces"
setup 1.2.0-SNAPSHOT  1.3.0-SNAPSHOT "" 7.4  1.2.0 "" 7.4
sh "$SCRIPT" 1.3.0-SNAPSHOT >/dev/null
check "develop's version wins"    "$(projver)"                                    "1.3.0-SNAPSHOT"
check "parent version untouched"  "$(grep -c '<version>3.3.5</version>' pom.xml)" "1"
check "comments survive"          "$(grep -c 'must survive' pom.xml)"             "1"
check "no conflict markers left"  "$(grep -c '<<<<<<<' pom.xml || true)"          "0"
check "no placeholder left"       "$(grep -c 'MERGE-PLACEHOLDER' pom.xml || true)" "0"
cd /; rm -rf "$D"

echo "pom edits made on BOTH branches survive"
setup 1.2.0-SNAPSHOT  1.3.0-SNAPSHOT added-on-develop 7.4  1.2.0 "" 8.0
sh "$SCRIPT" 1.3.0-SNAPSHOT >/dev/null
check "develop's version wins"      "$(projver)"                            "1.3.0-SNAPSHOT"
check "develop's new dependency"    "$(grep -c 'added-on-develop' pom.xml)" "1"
check "release's dependency bump"   "$(grep -c '<logstash.version>8.0<' pom.xml)" "1"
cd /; rm -rf "$D"

echo "a genuine conflict outside the version is refused, not guessed at"
setup 1.2.0-SNAPSHOT  1.3.0-SNAPSHOT "" 9.9  1.2.0 "" 8.0
if sh "$SCRIPT" 1.3.0-SNAPSHOT >/dev/null 2>&1; then
  check "refuses to auto-resolve" "resolved" "refused"
else
  check "refuses to auto-resolve" "refused" "refused"
fi
cd /; rm -rf "$D"

if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "all resolve-pom-merge tests passed"
