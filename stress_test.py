"""
Stress test klastra Spark — symuluje N analityków połączonych jednocześnie.
Każdy analityk uruchamia CPU-heavy job (Pi Monte Carlo + aggregacje na dużym DF).
"""
import sys
import threading
import time
from datetime import datetime

MASTER_IP   = "34.38.35.111"
AUTH_SECRET = "Zk8#Xp3$mV7@nQ2!rT9wL4"
N_ANALITYCY  = int(sys.argv[1]) if len(sys.argv) > 1 else 8
ROWS        = 5_000_000  # wierszy per job

results = {}
lock = threading.Lock()


def analityk_job(analityk_id: str):
    from pyspark.sql import SparkSession
    from pyspark.sql import functions as F

    t0 = time.time()
    status = "OK"
    detail = ""

    try:
        spark = (
            SparkSession.builder
            .remote(f"sc://{MASTER_IP}:15002")
            .getOrCreate()
        )

        # Job 1: Pi szacowanie (Monte Carlo) — DataFrame API
        df_pi = spark.range(ROWS).select(
            (F.rand() * 2 - 1).alias("x"),
            (F.rand() * 2 - 1).alias("y"),
        )
        inside = df_pi.filter(F.col("x")**2 + F.col("y")**2 < 1).count()
        pi = 4.0 * inside / ROWS

        # Job 2: Aggregacje na syntetycznym DF
        df = spark.range(ROWS).select(
            F.col("id"),
            (F.col("id") % 100).alias("group"),
            F.sin(F.col("id").cast("double")).alias("val"),
        )
        agg = df.groupBy("group").agg(
            F.count("id").alias("cnt"),
            F.avg("val").alias("avg_val"),
            F.stddev("val").alias("std_val"),
        )
        n_groups = agg.count()

        detail = f"pi≈{pi:.4f}, groups={n_groups}"
        spark.stop()

    except Exception as e:
        status = "ERR"
        detail = str(e)[:120]

    elapsed = time.time() - t0
    with lock:
        results[analityk_id] = {"status": status, "elapsed": elapsed, "detail": detail}
        done = sum(1 for r in results.values() if r["status"] in ("OK", "ERR"))
        print(f"  [{done:>2}/{N_ANALITYCY}] {analityk_id:12s} {status}  {elapsed:6.1f}s  {detail}")


def main():
    print(f"\n{'='*65}")
    print(f"Stress test: {N_ANALITYCY} równoległych analityków × {ROWS:,} wierszy")
    print(f"Cluster:     sc://{MASTER_IP}:15002")
    print(f"Start:       {datetime.now().strftime('%H:%M:%S')}")
    print(f"{'='*65}")

    threads = []
    t_start = time.time()
    for i in range(1, N_ANALITYCY + 1):
        sid = f"analityk{i:02d}"
        t = threading.Thread(target=analityk_job, args=(sid,), daemon=True)
        threads.append(t)

    # Startuj z lekkim przesunięciem żeby nie zawalić klastra naraz
    for t in threads:
        t.start()
        time.sleep(0.3)

    for t in threads:
        t.join(timeout=300)

    total = time.time() - t_start
    ok  = sum(1 for r in results.values() if r["status"] == "OK")
    err = sum(1 for r in results.values() if r["status"] == "ERR")
    avg = sum(r["elapsed"] for r in results.values()) / len(results) if results else 0

    print(f"\n{'='*65}")
    print(f"Wynik:   {ok} OK  /  {err} ERR  z {N_ANALITYCY} analityków")
    print(f"Czas:    łączny {total:.1f}s  |  średni job {avg:.1f}s")
    print(f"{'='*65}\n")

    if err:
        print("Błędy:")
        for sid, r in results.items():
            if r["status"] == "ERR":
                print(f"  {sid}: {r['detail']}")


if __name__ == "__main__":
    main()
