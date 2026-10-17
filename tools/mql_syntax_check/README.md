# MQL5 syntax check (no MetaEditor needed)

Converts an `.mq5` file to C++ against a stub header (`shim.h`) and runs `g++ -fsyntax-only`.
It catches typos, undeclared names, wrong argument counts and type errors in the EA's own code.
It does **not** prove the MQL5 API calls are right; always compile in MetaEditor (F7) too.

```bash
python3 convert.py ../../MQL5/Experts/HedgeDailyEA_v2.mq5 /tmp/ea.cpp
g++ -std=c++17 -fsyntax-only -Wall -I. /tmp/ea.cpp
```
