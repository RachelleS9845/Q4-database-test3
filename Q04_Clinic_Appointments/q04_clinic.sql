/* =====================================================================
   ICT371 Advanced Database — Question 4: Clinic Appointment Scheduling
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rule : slots 09:00, 10:00, 11:00, 12:00. Two NON-CANCELLED appointments
          may never share the same doctor + day + slot.
   ===================================================================== */

DROP SCHEMA IF EXISTS q04_clinic CASCADE;
CREATE SCHEMA q04_clinic;
SET search_path TO q04_clinic, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE patients (
    patient_id  SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL      PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL
        CONSTRAINT chk_slot_time CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date     DATE    PRIMARY KEY,
    booked_count     INTEGER NOT NULL DEFAULT 0,
    attended_count   INTEGER NOT NULL DEFAULT 0,
    cancelled_count  INTEGER NOT NULL DEFAULT 0
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_daily_load(p_doctor_id, p_day)  [6 marks]
   Number of that doctor's non-cancelled appointments that day.
   COUNT(*) returns 0 (not NULL) when there are no bookings.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
SET search_path = q04_clinic, public
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Doctor % does not exist', p_doctor_id USING ERRCODE = 'P0002';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
    AND   appointment_day = p_day
    AND   status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot)  [8 marks]
   Validates IDs, rejects a past date or an unsupported slot, inserts BOOKED.
   The clash check itself is done by the trigger in (d), so it also protects
   direct SQL.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
SET search_path = q04_clinic, public
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Booking rejected: patient % does not exist', p_patient_id USING ERRCODE = 'P0002';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Booking rejected: doctor % does not exist', p_doctor_id USING ERRCODE = 'P0002';
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Booking rejected: % is in the past (or missing)', p_day USING ERRCODE = '22023';
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Booking rejected: % is not a clinic slot (09:00, 10:00, 11:00, 12:00)', p_slot
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED')
    RETURNING appointment_id INTO v_id;

    RAISE NOTICE 'Appointment % booked: doctor % on % at %', v_id, p_doctor_id, p_day, p_slot;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — BEFORE INSERT OR UPDATE: reject slot clashes  [8 marks]
   On UPDATE the row being changed is excluded from the search, so editing
   an appointment (e.g. marking it ATTENDED) does not clash with itself.
   Locking the doctor row makes two simultaneous bookings wait in turn.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_check_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q04_clinic, public
AS $$
BEGIN
    -- a cancelled appointment never occupies a slot
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM   appointments a
        WHERE  a.doctor_id       = NEW.doctor_id
        AND    a.appointment_day = NEW.appointment_day
        AND    a.slot_time       = NEW.slot_time
        AND    a.status         <> 'CANCELLED'
        AND    (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time
              USING ERRCODE = '23505';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_slot_clash();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 patients, 3 doctors, 6 appointments (no clashes).
   Past history (yesterday) is entered directly, because the procedure
   correctly refuses past dates; today/future go through the procedure.
   --------------------------------------------------------------------- */
INSERT INTO patients (full_name) VALUES ('Mwila Banda'), ('Chanda Phiri'), ('Natasha Zulu');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mulenga'), ('Dr. Sakala'),   ('Dr. Tembo');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED');

CALL pr_book_appointment(2, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '11:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '12:00');

SELECT * FROM appointments ORDER BY appointment_day, doctor_id, slot_time;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT fn_daily_load(1, CURRENT_DATE - 1) AS dr1_yesterday,    -- 1 (cancelled not counted)
       fn_daily_load(1, CURRENT_DATE)     AS dr1_today,        -- 1
       fn_daily_load(3, CURRENT_DATE + 30) AS dr3_free_day;    -- 0

DO $$
BEGIN
    BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_daily_load(99)  -> %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(9, 1, CURRENT_DATE + 2, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown patient    -> %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 9, CURRENT_DATE + 2, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown doctor     -> %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 5, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Past date          -> %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '14:30');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Bad slot           -> %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');           -- clash via procedure
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Clash (procedure)  -> %', SQLERRM; END;
    BEGIN INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
          VALUES (1, 2, CURRENT_DATE, '11:00');                            -- clash via direct SQL
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Clash (direct SQL) -> %', SQLERRM; END;
    BEGIN UPDATE appointments SET doctor_id = 2, slot_time = '11:00'       -- move appt 4 onto Dr. Sakala's
          WHERE appointment_id = 4;                                        -- taken 11:00 slot today
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Clash (UPDATE)     -> %', SQLERRM; END;
END $$;

-- allowed: yesterday's 10:00 for Dr. Mulenga was CANCELLED, so it may be re-used
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (3, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED');

-- allowed: updating an appointment does not clash with itself
UPDATE appointments SET status = 'BOOKED'
WHERE doctor_id = 3 AND appointment_day = CURRENT_DATE + 1;

SELECT COUNT(*) AS total_appointments FROM appointments;   -- 7

/* ---------------------------------------------------------------------
   (e) VIEW v_today_appointments — today's BOOKED only  [5 marks]
   Only the columns the front desk needs; no other patient details.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
AND    a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

/* ---------------------------------------------------------------------
   (f) NON-UNIQUE INDEX — appointments by appointment_day and doctor_id  [5 marks]
   Justification: the clinic's daily screens and the clash check always ask
   "this day, this doctor". A composite (appointment_day, doctor_id) index
   finds those few rows directly. It must be NON-unique because one doctor
   legitimately has up to four appointments (plus cancelled ones) per day.
   --------------------------------------------------------------------- */
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

EXPLAIN
SELECT appointment_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
AND    doctor_id = 1;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT appointment_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
AND    doctor_id = 1;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_clinic_summary(p_day)  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q04_clinic, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;

    RAISE NOTICE 'clinic_summary refreshed for %', p_day;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces: 0 booked, 3 attended, 1 cancelled
SELECT * FROM clinic_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q04_refresh_clinic_summary',
    '0 1 * * *',                                   -- 01:00 every day
    $$CALL q04_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q04_refresh_clinic_summary';
