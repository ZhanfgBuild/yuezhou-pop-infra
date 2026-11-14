#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract just the env helpers and run them against a filled .env under errexit.
# shellcheck disable=SC1090
{
  echo 'set -Eeuo pipefail'
  echo "ENV_FILE=\"$TMP/.env\""
  sed -n '/^generate_secret()/,/^}/p; /^replace_env_value()/,/^}/p; /^ensure_env()/,/^}/p' "$ROOT/stack.sh"
  # override the example/file bootstrap for the extracted function
  echo 'ensure_env() {
  chmod 600 "$ENV_FILE"
  if grep -q "^POSTGRES_PASSWORD=GENERATED_ON_INSTALL$" "$ENV_FILE"; then
    replace_env_value POSTGRES_PASSWORD "$(generate_secret)"
  fi
  if grep -q "^VALKEY_PASSWORD=GENERATED_ON_INSTALL$" "$ENV_FILE"; then
    replace_env_value VALKEY_PASSWORD "$(generate_secret)"
  fi
}'
} > "$TMP/helpers.sh"

# The extracted original ensure_env still references ENV_EXAMPLE; the second
# definition above overrides it. Source and run with an already-filled env.
cat > "$TMP/.env" <<'ENV'
POSTGRES_PASSWORD=already-set
VALKEY_PASSWORD=already-set
ENV
chmod 600 "$TMP/.env"
# Build a runner that defines replace/generate from stack.sh and the fixed if/fi body.
python3 - << PY
from pathlib import Path
root = Path("$ROOT")
tmp = Path("$TMP")
src = root.joinpath("stack.sh").read_text()
def extract(name):
    start = src.index(f"{name}() {{")
    depth = 0
    for i, line in enumerate(src[start:].splitlines(True)):
        depth += line.count("{") - line.count("}")
        if i > 0 and depth == 0:
            return src[start:start+sum(map(len, src[start:].splitlines(True)[:i+1]))]
    raise SystemExit(name)
text = "set -Eeuo pipefail\\n" + extract("generate_secret") + "\\n" + extract("replace_env_value") + "\\n" + extract("ensure_env")
# Rewrite the leading bootstrap of ensure_env so the test can inject ENV_FILE only.
# Call the real ensure_env after creating a fake ENV_EXAMPLE? Simpler: run a
# minimal copy of the file with ROOT-like names.
tmp.joinpath("run.sh").write_text(text)
print("extracted")
PY

# Use a slim copy of stack.sh functions with ENV_FILE/ENV_EXAMPLE pointed at TMP.
cp "$ROOT/.env.example" "$TMP/.env.example" 2>/dev/null || true
# If example missing, synthesize one.
if [[ ! -f "$TMP/.env.example" ]]; then
  printf 'POSTGRES_PASSWORD=GENERATED_ON_INSTALL\nVALKEY_PASSWORD=GENERATED_ON_INSTALL\n' > "$TMP/.env.example"
fi
cat > "$TMP/.env" <<'ENV'
POSTGRES_PASSWORD=already-set
VALKEY_PASSWORD=already-set
ENV
chmod 600 "$TMP/.env"

# Run the real ensure_env by temporarily pointing paths via a wrapper.
# We source extracted functions and set ENV_FILE/ENV_EXAMPLE.
bash -c '
set -Eeuo pipefail
ENV_FILE="'"$TMP"'/.env"
ENV_EXAMPLE="'"$TMP"'/.env.example"
'"$(python3 - << PY
from pathlib import Path
src = Path("$ROOT/stack.sh").read_text()
for name in ("generate_secret", "replace_env_value", "ensure_env"):
    start = src.index(f"{name}() {{")
    depth = 0
    acc = []
    for line in src[start:].splitlines(True):
        acc.append(line)
        depth += line.count("{") - line.count("}")
        if len(acc) > 1 and depth == 0:
            break
    print("".join(acc))
    print()
PY
)"'
ensure_env
grep -q "^POSTGRES_PASSWORD=already-set$" "'"$TMP"'/.env"
grep -q "^VALKEY_PASSWORD=already-set$" "'"$TMP"'/.env"
echo PASS filled-env-does-not-abort
'

# Placeholder values should still be replaced.
cat > "$TMP/.env" <<'ENV'
POSTGRES_PASSWORD=GENERATED_ON_INSTALL
VALKEY_PASSWORD=GENERATED_ON_INSTALL
ENV
chmod 600 "$TMP/.env"
bash -c '
set -Eeuo pipefail
ENV_FILE="'"$TMP"'/.env"
ENV_EXAMPLE="'"$TMP"'/.env.example"
'"$(python3 - << PY
from pathlib import Path
src = Path("$ROOT/stack.sh").read_text()
for name in ("generate_secret", "replace_env_value", "ensure_env"):
    start = src.index(f"{name}() {{")
    depth = 0
    acc = []
    for line in src[start:].splitlines(True):
        acc.append(line)
        depth += line.count("{") - line.count("}")
        if len(acc) > 1 and depth == 0:
            break
    print("".join(acc))
    print()
PY
)"'
ensure_env
! grep -q "GENERATED_ON_INSTALL" "'"$TMP"'/.env"
grep -q "^POSTGRES_PASSWORD=." "'"$TMP"'/.env"
echo PASS placeholders-are-replaced
'
echo ALL_PASS
