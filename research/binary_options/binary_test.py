"""Win rate of popular Quotex-style signals: trade from the signal candle's close to N candles later.

Data: QuantConnect Lean sample data (Oanda bid/ask, mid prices are used). Without cloning all of Lean:

    git clone --depth 1 --filter=blob:none --sparse https://github.com/QuantConnect/Lean
    cd Lean && git sparse-checkout set --no-cone /Data/forex/oanda/minute/eurusd/ \
        /Data/cfd/oanda/minute/xauusd/ /Data/cfd/oanda/hour/xauusd.zip

    LEAN_DATA=path/to/Lean/Data python binary_test.py
"""
import glob, io, math, os, zipfile
import numpy as np
import pandas as pd

DATA = os.environ.get("LEAN_DATA", "Data")
PAYOUT = 0.85                     # Quotex-style payout on a win; a loss loses the full stake
BREAKEVEN = 1 / (1 + PAYOUT)


def load_minutes(folder):
    frames = []
    for f in sorted(glob.glob(os.path.join(folder, "*.zip"))):
        day = pd.Timestamp(os.path.basename(f)[:8])
        z = zipfile.ZipFile(f)
        d = pd.read_csv(io.BytesIO(z.read(z.namelist()[0])), header=None,
                        names=["ms", "bo", "bh", "bl", "bc", "bs", "ao", "ah", "al", "ac", "as"])
        d.index = day + pd.to_timedelta(d.ms, unit="ms")
        frames.append(pd.DataFrame({"o": (d.bo + d.ao) / 2, "h": (d.bh + d.ah) / 2,
                                    "l": (d.bl + d.al) / 2, "c": (d.bc + d.ac) / 2}))
    return pd.concat(frames)


def load_gold_h1():
    z = zipfile.ZipFile(os.path.join(DATA, "cfd", "oanda", "hour", "xauusd.zip"))
    d = pd.read_csv(io.BytesIO(z.read(z.namelist()[0])), header=None,
                    names=["t", "bo", "bh", "bl", "bc", "bs", "ao", "ah", "al", "ac", "as"])
    d.index = pd.to_datetime(d.t, format="%Y%m%d %H:%M")
    return pd.DataFrame({"o": (d.bo + d.ao) / 2, "h": (d.bh + d.ah) / 2,
                         "l": (d.bl + d.al) / 2, "c": (d.bc + d.ac) / 2})


def rsi(c, n):
    d = c.diff()
    up = d.clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    dn = (-d).clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    return 100 - 100 / (1 + up / dn.replace(0, np.nan))


def signals(df):
    c, o = df.c, df.o
    r14, r7 = rsi(c, 14), rsi(c, 7)
    mid, sd = c.rolling(20).mean(), c.rolling(20).std(ddof=0)
    e9, e21 = c.ewm(span=9, adjust=False).mean(), c.ewm(span=21, adjust=False).mean()
    col = np.sign(c - o)
    streak3 = (col == col.shift(1)) & (col == col.shift(2)) & (col != 0)
    rng = np.random.default_rng(7)
    S = {
        "RSI14 30/70 reversal": np.where(r14 < 30, 1, np.where(r14 > 70, -1, 0)),
        "RSI7 20/80 reversal": np.where(r7 < 20, 1, np.where(r7 > 80, -1, 0)),
        "Bollinger 20/2 reversal": np.where(c < mid - 2 * sd, 1, np.where(c > mid + 2 * sd, -1, 0)),
        "EMA 9/21 cross (trend)": np.where((e9 > e21) & (e9.shift(1) <= e21.shift(1)), 1,
                                           np.where((e9 < e21) & (e9.shift(1) >= e21.shift(1)), -1, 0)),
        "3 same candles -> reverse": np.where(streak3, -col, 0),
        "3 same candles -> follow": np.where(streak3, col, 0),
        "Follow last candle": col.values,
        "Coin flip (baseline)": rng.choice([-1, 1], size=len(df)),
    }
    return {k: pd.Series(v, index=df.index) for k, v in S.items()}


def evaluate(df, expiry):
    fut = df.c.shift(-expiry) - df.c
    rows = []
    for name, sig in signals(df).items():
        m = (sig != 0) & fut.notna()
        res = np.sign(fut[m] * sig[m])
        wins, losses, ties = int((res > 0).sum()), int((res < 0).sum()), int((res == 0).sum())
        n = wins + losses
        wr = wins / n if n else float("nan")
        ci = 1.96 * math.sqrt(wr * (1 - wr) / n) if n else float("nan")
        ev = wr * PAYOUT - (1 - wr)
        rows.append({"strategy": name, "trades": n, "ties_refunded": ties, "win_%": round(100 * wr, 1),
                     "95%_range": f"{100 * (wr - ci):.1f}-{100 * (wr + ci):.1f}",
                     "profit_per_$100_staked": round(100 * ev, 1)})
    return pd.DataFrame(rows)


def stake_sim(df, expiry, name, start=100.0, stake=1.0, martingale=False, max_steps=7):
    """$100 account, $1 trades (or martingale x2.2 after each loss) on every signal, one trade at a time."""
    sig = signals(df)[name]
    fut = (df.c.shift(-expiry) - df.c).values
    bal, step, i, n, lowest = start, 0, 0, len(df), start
    s = sig.values
    while i < n - expiry:
        if s[i] != 0 and not np.isnan(fut[i]):
            amt = stake * (2.2 ** step if martingale else 1.0)
            if amt > bal:
                return bal, lowest, True
            r = np.sign(fut[i] * s[i])
            if r > 0:
                bal += amt * PAYOUT; step = 0
            elif r < 0:
                bal -= amt; step = min(step + 1, max_steps - 1) if martingale else 0
            lowest = min(lowest, bal)
            i += expiry
        else:
            i += 1
    return bal, lowest, False


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    sets = {"EURUSD M1 (May 2014)": load_minutes(os.path.join(DATA, "forex", "oanda", "minute", "eurusd")),
            "XAUUSD M1 (May 2014)": load_minutes(os.path.join(DATA, "cfd", "oanda", "minute", "xauusd"))}
    for k, df in sets.items():
        print(f"{k}: {len(df)} one-minute candles")
    print(f"payout {PAYOUT:.0%} -> you need more than {BREAKEVEN:.1%} wins to break even\n")
    for k, df in sets.items():
        for exp in (1, 5):
            print(f"== {k}, expiry {exp} min"); print(evaluate(df, exp).to_string(index=False)); print()
    g = load_gold_h1()
    print(f"== XAUUSD H1 2006-2019 ({len(g)} candles), expiry 1 hour"); print(evaluate(g, 1).to_string(index=False)); print()
    df = sets["EURUSD M1 (May 2014)"]
    for name in ("RSI14 30/70 reversal", "3 same candles -> reverse"):
        for mg in (False, True):
            bal, low, broke = stake_sim(df, 1, name, martingale=mg)
            print(f"$100 account, EURUSD 1-min, {name}, {'martingale x2.2' if mg else 'fixed $1'}: "
                  f"end ${bal:.2f}, lowest ${low:.2f}{', ACCOUNT BLOWN' if broke else ''}")
