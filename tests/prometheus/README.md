# Prometheus rule tests

Run from the repo root with local `promtool` and PyYAML installed:

```sh
python3 tests/prometheus/run.py
```

The runner extracts the actual PrometheusRule `spec` of each suite's manifest
into a temporary rules file, runs `promtool check rules` then `promtool test
rules`, and removes its temporary directory even on failure. Nothing is
downloaded. Suites (listed in `run.py`):

- `etcd-disk.test.yaml` — `config/etcd-disk-alerts.yaml`, described below.
- `job-failure.test.yaml` — `config/job-failure-alerts.yaml`:
  `KubeCronJobLastRunFailed` follows the newest FINISHED run of each CronJob
  (stale retained failures, in-flight runs, retry-then-success, recovery and
  re-failure, duplicate kube-state-metrics series), and `KubeJobFailed` is left
  only for Jobs no CronJob owns. A control case shows the stock expression
  (switched off through `defaultRules`) latching on
  the stale fixture.

## etcd WAL fsync alerts

A seven-day Grafana backtest covered 2026-09-22 through 09-29 on node-3
(`192.0.2.13:2381`). The 1h slow fraction was normally 1.0–1.5%, so the old
`>1%/1h` warning would fire nearly continuously. The 6h baseline was 1.1–1.3%,
typical backup nights 2.0–2.7%, and the worst night 3.3%. Warning now requires
**>4% over 6h for 15m**. Critical remains **>5% over both 1h and 6h for 5m**;
it never fired in the seven-day backtest.

The 21 cases use one-minute counter samples and assert alert severity and
instance labels. The backtest models use a constant 100 fsyncs/s on node-3
and a healthy peer at 100x volume, ensuring that global aggregation cannot
hide degradation. They cover:

- A steady 1.3% baseline for 12h, with no warning or critical at any point.
- A typical night: 1.2% baseline, one hour at 6% starting 22:30, then one hour
  at 4% starting 01:30. The 6h fraction peaks at about 2.47%; neither alert fires.
- A worst-night model reaching about 3.30% over 6h: hourly spikes at 7.1%, 4%,
  and 3%, with 1.9% between spikes and 1.2% outside the night. The 1.9% level
  and 3% pre-dawn spike are synthetic choices to match the observed 6h maximum, not a measured raw
  trace. Neither alert fires anywhere in the simulation.
- Sustained 4.5% degradation after six baseline hours: warning becomes pending
  at minute 665, remains pending at 679, and fires at 680; critical stays quiet.
- A clearly bad two-hour night at 10%: 6h reaches about 4.14%, warning fires
  after its 15m hold, and critical stays quiet despite the high 1h fraction.
- Sustained 30% degradation and repeated ten-minute flapping after six healthy
  hours still page. Recovery clears critical on the 1h condition while warning
  remains until the 6h fraction falls to 4% or below.

Other cases cover flapping, a one-minute spike, steady 2%,
strict 4%/5% boundaries, zero/missing traffic, counter reset, and the different
holds (critical fires at minute 6, warning at 16). The older single/double
20-minute backups at 30% now assert neither warning nor critical across the
whole simulation. Explicit backend and missing-metric cases also protect the
unchanged 30m/15m holds and recovery behavior.

The ratios are event-weighted, not averages of percentiles. With aligned
one-minute samples, full 6h/1h range selectors exclude the left endpoint and
span 359/59 counter increments; common rate extrapolation cancels in these
constant-volume ratios. Night models start at 16:30 with six baseline hours.
These are synthetic regressions based on the operator's observations, not a replay of
Grafana samples. The windows do not enforce minimum history: new series can
alert before six hours have accumulated.
