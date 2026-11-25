# Question 4 — Clinic Appointment Scheduling

**Script:** [`q04_clinic.sql`](q04_clinic.sql) · **Schema:** `q04_clinic` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q04_clinic.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q04_clinic.sql
```

The script drops and recreates the `q04_clinic` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `patients`, `doctors`, `appointments`, `clinic_summary` | `slot_time TIME` restricted by CHECK to 09:00/10:00/11:00/12:00. `status` CHECK allows BOOKED/ATTENDED/CANCELLED. Six clash-free appointments: yesterday's history entered directly, today's and tomorrow's through the procedure. |
| (b) Function [6] | `fn_daily_load(p_doctor_id, p_day)` | `COUNT(*)` of non-cancelled appointments, which is naturally 0 on a free day. An unknown doctor raises an error. |
| (c) Procedure [8] | `pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot)` | Validates both IDs, rejects a past or NULL date and an unsupported slot, then inserts a BOOKED row. The clash check itself is left to the trigger, so direct SQL is covered too. |
| (d) Trigger [8] | `trg_appointments_no_clash` (BEFORE INSERT OR UPDATE) | Rejects a row if another **non-cancelled** appointment has the same doctor, day and slot. On UPDATE, `appointment_id <> NEW.appointment_id` excludes the row being changed. It locks the doctor row so two simultaneous bookings cannot both succeed. Tests cover a clash through the procedure, through direct INSERT and through UPDATE, and also show re-using a cancelled slot is allowed. |
| (e) View [5] | `v_today_appointments` | Today's BOOKED appointments with ID, slot, patient name and doctor name only. No other patient data is exposed. |
| (f) Index [5] | `idx_appointments_day_doctor (appointment_day, doctor_id)` | Non-unique, because a doctor has several appointments a day (and cancelled duplicates of a slot). It serves the daily schedule and the clash search. |
| (g) Job [6] | `pr_refresh_clinic_summary(p_day)` + cron `0 1 * * *` | `COUNT(*) FILTER (WHERE status = …)` for each status, saved with an upsert. The job runs at 01:00 for the previous day. |

## Expected results (verified on PostgreSQL 16)

Every clash test is rejected with 'Slot clash…'. The view shows 2 appointments for today. Yesterday's summary is 0 booked / 3 attended / 1 cancelled.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
