import re, sys
src = open(sys.argv[1]).read()
lines = src.splitlines()
out, protos = [], []
sig = re.compile(r"^(?!return|else|if|for|while)([A-Za-z_][\w<>]*)\s+([A-Za-z_]\w*)\((.*)\)\s*$")
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith("#property") or s.startswith("#include") or s.startswith("input group"):
        continue
    line = re.sub(r"^input\s+", "const ", line)
    line = re.sub(r"\b(\w+)\s+(\w+)\[\];", r"Arr<\1> \2;", line)
    m = sig.match(line)
    if m and i + 1 < len(lines) and lines[i + 1].strip() == "{":
        protos.append(line + ";")
        line = re.sub(r"\s*=\s*[^,)]+", "", line)  # defaults live in the prototype
    out.append(line)
# prototypes must come after type declarations: insert them before the first function definition
first = next(i for i, l in enumerate(out) if sig.match(l) and (i + 1 < len(out) and out[i + 1].strip() == "{"))
code = out[:first] + ["// --- prototypes"] + protos + out[first:]
open(sys.argv[2], "w").write('#include "shim.h"\n' + "\n".join(code) + "\n")
