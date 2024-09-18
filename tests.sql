CREATE database gotchas



-- A.1) Primary keys aren't unique
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = MergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- We now have two persons with the same id
SELECT * FROM person;



-- A.2) Each table may behave differently, depending on its engine
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- Alice was renamed to Bob.
SELECT * FROM person FINAL;



-- A.3) Merges may NEVER happen
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- Alice was NOT renamed to Bob.
SELECT * FROM person;
SYSTEM START MERGES person;



-- A.4) The `FINAL` keyword affects the query result, but not the underlying data
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- Alice was renamed to Bob in this query result
SELECT * FROM person FINAL;
-- But not in the underlying table
SELECT * FROM person;
-- We can force finalization in the actual data:
SYSTEM START MERGES person;
OPTMIZE TABLE person FINAL;
SELECT * FROM person;



-- B.1) A materialized view is just an insert trigger
DROP TABLE IF EXISTS sales;
CREATE TABLE sales (product String, amount Int32) ENGINE = SummingMergeTree() ORDER BY product;
-- Create a materialized view that filters out products with less than 50 total sales
DROP VIEW IF EXISTS top_products;
CREATE MATERIALIZED VIEW top_products (product String, amount Int32) ORDER BY amount
AS
    SELECT product, SUM(amount) as amount
    FROM sales
    GROUP BY product
    HAVING SUM(sales.amount) > 50;
-- Add some sales
INSERT INTO sales (product, amount) VALUES ('apple', 30);
INSERT INTO sales (product, amount) VALUES ('apple', 40);
INSERT INTO sales (product, amount) VALUES ('banana', 60);
-- Both products have > 50 total sales
SELECT * FROM sales FINAL;
-- But only the banana is in the materialized view
SELECT * FROM top_products;



-- B.2) A materialized view is NOT just an insert trigger
-- This needs [Kafka](https://kafka.apache.org/) setup and listening on port 9092.
DROP TABLE IF EXISTS kafka;
CREATE TABLE kafka (id Int32, message String)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'localhost:9092', kafka_topic_list = 'my_message', kafka_group_name = 'my_consumers', kafka_format = 'JSONEachRow';
-- Run:
--    kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group my_consumers
-- It should say 'Consumer group my_consumers does not exist.'
DROP VIEW IF EXISTS kafka_log_mv;
-- This makes clickhouse a kafka consumer
CREATE MATERIALIZED VIEW kafka_log_mv (id Int32, message String) ORDER BY id
AS SELECT (id, message) FROM kafka;
-- Run the same command again:
--    kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group my_consumers
-- It now shows ClickHouse is in the my_consumers group



-- B.3) Materialize view column names have to match exactly
DROP TABLE IF EXISTS sales;
CREATE TABLE sales (product String, amount Int32) ENGINE = SummingMergeTree() ORDER BY product;
-- Create a materialized view that filters out products with less than 50 total sales
DROP VIEW IF EXISTS top_products;
CREATE MATERIALIZED VIEW top_products (product String, amount Int32) ORDER BY amount
AS
    SELECT product, SUM(amount) -- forgot to name the column
    FROM sales
    GROUP BY product
    HAVING SUM(sales.amount) > 50;
-- Add a sale
INSERT INTO sales (product, amount) VALUES ('banana', 60);
-- The 'banana' record is inserted, but amount is 0
SELECT * FROM top_products;


DROP TABLE IF EXISTS sales;
CREATE TABLE sales (product String, amount Int32) ENGINE = SummingMergeTree() ORDER BY product;
-- Create a materialized view that filters out products with less than 50 total sales
DROP VIEW IF EXISTS top_products;
CREATE MATERIALIZED VIEW top_products (product String, amount Int32) ORDER BY amount
AS
    SELECT SUM(amount) as amount, product
    FROM sales
    GROUP BY product
    HAVING SUM(sales.amount) > 50;
-- Add a sale
INSERT INTO sales (product, amount) VALUES ('banana', 60);
-- The 'banana' record is inserted, but amount is 0
SELECT * FROM top_products;



-- C.1)
DROP TABLE IF EXISTS events;
CREATE TABLE events (date Date, event String, occurences Int32)
ENGINE = SummingMergeTree() ORDER BY event;
SYSTEM STOP MERGES events;
-- Add some events
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'deadlock',30);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'deadlock', 40);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'server error', 60);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'unauthorised', 10);
-- Now add a TTL that should delete old records if the total is < 50
SET materialize_ttl_after_modify=1;
SYSTEM START MERGES events;
ALTER TABLE events MODIFY TTL date + INTERVAL 1 MONTH DELETE WHERE occurences < 50;
-- This should only delete the 'unauthorised' events record,
-- because the total for deadlocks is 70.
-- But if the records aren't merged, ClickHouse will delete the deadlock records as well.
SELECT * FROM events;



-- C.2)
DROP TABLE IF EXISTS events;
CREATE TABLE events (date Date, event String, occurences Int32) ENGINE = SummingMergeTree() ORDER BY event;
SYSTEM STOP MERGES events;
-- Add some events
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'deadlock', 30);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'deadlock', 40);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'server error', 60);
INSERT INTO events (date, event, occurences) VALUES ('2024-01-01', 'unauthorised', 10);
-- Now add a TTL that should first force the merging of any unmerged records,
-- and one hour later delete old records if the total is < 50
SYSTEM START MERGES events;
SET materialize_ttl_after_modify=1;
ALTER TABLE events MODIFY TTL
    date + INTERVAL 1 MONTH - INTERVAL 1 HOUR GROUP BY event SET occurences = SUM(occurences),
    date + INTERVAL 1 MONTH DELETE WHERE occurences < 50;
-- The result depends on which rule ClickHouse decides to process first.
-- If it's the GROUP BY, the deadlock records remain, if it's the DELETE, they get deleted.
SELECT * FROM events;



-- D.1) Non-aggregated columns in a SummingMergeTree
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree() PRIMARY KEY id;
INSERT INTO person (id, name, score) VALUES (1, 'Alice', 10);
INSERT INTO person (id, name, score) VALUES (1, 'Bob', 15);
-- This shows Alice with a score of 25
SELECT * FROM person FINAL;



-- D.2) Adding columns to a SummingMergeTree with an explicit column list
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree(score) PRIMARY KEY id;
-- Some time passes, and we add a 'games' column to count the number of games played
ALTER TABLE person ADD COLUMN games Int32;
INSERT INTO person (id, name, score, games) VALUES (1, 'Alice', 10, 1);
INSERT INTO person (id, name, score, games) VALUES (1, 'Bob', 15, 1);
-- This shows Alice with a score of 25, and ONE game played, NOT two.
SELECT * FROM person FINAL;

DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree(score) PRIMARY KEY id;
-- Some time passes, and we add a 'games' column to count the number of games played
-- This time using AggregateFunction, so it should be very clear we want aggregation
ALTER TABLE person ADD COLUMN games AggregateFunction(count);
INSERT INTO person (id, name, score, games) SELECT 1, 'Alice', 10, countState();
INSERT INTO person (id, name, score, games) SELECT 1, 'Bob', 15, countState();
-- This shows Alice with a score of 25, and ONE game played, NOT two.
SELECT id, name, score, finalizeAggregation(games) AS games FROM person FINAL;



-- E.1) SYSTEM STOP MERGES also stops OPTIMIZE TABLE
-- Normal ReplacingMergeTree
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- Error.
OPTIMIZE TABLE person FINAL;



-- E.2) SYSTEM STOP MERGES has a different effect on Replicated tables
-- ReplicatedReplacingMergeTree
DROP TABLE IF EXISTS person;
CREATE TABLE person ON CLUSTER '{cluster}' (id UInt32, name String)
ENGINE = ReplicatedReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- THIS BLOCKS INDEFINITELY!
OPTIMIZE TABLE person FINAL;
-- Until we do this on another connection
SYSTEM START MERGES person;



-- E.3) Stopping merges on a table that doesn't exist, isn't an error?
DROP TABLE IF EXISTS person;
-- Table doesn't exist yet, but this doesn't give an error!
SYSTEM STOP MERGES person;
-- And it doesn't work after the table is created
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- The merge just happens:
OPTIMIZE TABLE person FINAL;
SELECT * FROM person;

-- Now do things in the correct order:
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- Error.
OPTIMIZE TABLE person FINAL;



-- E.4) `DELETE FROM` is a merge AND it also block for non-Replicated tables.
-- Normal ReplacingMergeTree
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- BLOCKS INDEFINITELY!
DELETE FROM person WHERE id=2
-- Until we do this on another connection
SYSTEM START MERGES person;


-- E.5) SYSTEM STOP MERGES doesn't stop merges on bulk inserts
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- These two records still get merged
INSERT INTO person (id, name) VALUES (2, 'Charles'), (2, 'Dylan');
SELECT * FROM person;



