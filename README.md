# ClickHouse gotchas

> In programming, a gotcha is a valid construct in a system, program or programming language that works as documented but is counter-intuitive and almost invites mistakes because it is both easy to invoke and unexpected or unreasonable in its outcome. ([Wikipedia](https://en.wikipedia.org/wiki/Gotcha_(programming)))


ClickHouse is a beautiful tool. For the right workloads, it's a very fast ("how on earth does it do that??"-fast).

Of course this performance comes at a price. ClickHouse takes some liberties with regards to consistency and timing. It's a sharp set of knives you can use to disect your data, or cut yourself.

I'm new to ClickHouse, and I've cut myself a number of times over the last few weeks. In the spirit of the many [Golang](https://github.com/golang-leipzig/gotchas) [Gotchas](https://github.com/kstenerud/go-gotchas) [found](https://medium.com/@betable/3-go-gotchas-590b8c014e0a) [on](https://github.com/lkumarjain/shades-of-golang) [different](https://yourbasic.org/golang/gotcha/) [sites](https://medium.com/@prachi__sharma/gotchas-in-go-ba5a111ad5ba), I've decided to document my wounds here.

If you're also getting started with ClickHouse, these may give you some feeling for what to expect and watch out for.

"Ter leering ende vermaeck."



# Merge trees
One of the main ways ClickHouse achieves its high performance is by optimising for rapid inserts, and then processing data in the background to support the queries we want to do. This leads to design choices that make a lot of sense, but also take some getting used to when coming from a 'normal' relational database.

## A.1) Primary keys aren't unique
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = MergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- We now have two persons with the same ID
SELECT * FROM person;
```

In most databases, the primary key uniquely identifies a record, but not in ClickHouse.

ClickHouse wants to accept and store data as quickly as possible, and lets you figure out how to aggregate when you query the data. It may of may not do some background processing to make this faster.



## A.2) Each table may behave differently, depending on its engine
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- Alice was renamed to Bob.
SELECT * FROM person FINAL;
```

ClickHouse doesn't like deletes or updates. Instead, it prefers to just append data, and it offers a set of 'table engines' with different behaviours that can be use to implement common patterns. This is both powerful, and potentially confusing since each table may behave differently, sometimes in very subtle ways.

The example here is the same example as above, but this time using a `ReplacingMergeTree`, instead of a `MergeTree`.

ClickHouse now replaces Alice with Bob because these records had the same primary key.

There are many different engines. SummingMergeTree and AggregatingMergeTree can aggregate instead of replace. There are Replicated versions of these to replicate data across a cluster. Engines to implement sharding, and engines to connect to other systems, for example one that writes all inserted data to a Kafka topic.



## A.3) Merges may NEVER happen
Without the `FINAL` in the previous example, you would most likely still see all 3 inserted records.

ClickHouse delays the MergeTree's processing so it can ingest data faster. It only stores it in the right place, and if it has some time available later on, it may start merging the records. In this case that means removing the older (1, 'Alice') record.

It's important to remember that if the system is under heavy load, _the merge may never happen_. In that case, the result will look like this forever:

```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
INSERT INTO person (id, name) VALUES (2, 'Charles');
-- Alice was NOT renamed to Bob.
SELECT * FROM person;
SYSTEM START MERGES person;
```

This behaviour makes sense too. The user may only be interested in a certain subset of the data, so if the system is heavily loaded, we can save resources by leaving it up to the user to decide what actually needs to be aggregated.

In the example above we've explicitly told ClickHouse to stop merges on this table, to simulate what might happen naturally when the system is under high load. This can be useful in tests to make sure the code behaves the way we want, even when records aren't merged.



## A.4) The `FINAL` keyword affects the query result, but not the underlying data
```
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
```

Not really a gotcha, but important to keep in mind: we can use the `FINAL` keyword to tell ClickHouse to finalize aggregation in the query result. But this doesn't change the underlying table, which could be a much more expensive operation compared to aggregating a limited result set in memory.

We can also force ClickHouse to finalize the aggregation in the table using `OPTIMIZE TABLE ... FINAL`. This can be very expensive and is not recommended, but there are situations where it may be necessary.



# Materialized views

Materialized views are very useful, for example in combination with aggregating engines like SummingMergeTree in the target table.

But while the name suggest it's some perspective on the underlying table, it's important to realize that they're really just insert triggers copying data from one table to another.

## B.1) A materialized view is just an insert trigger
```
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
```

This example sets up a table with sales, and a materialized view that should select the products with a total amount over 50.

The `SELECT` on the `sales` *table* will give us the right result, but `top_products` will only contain the banana.

This is because the materialized view's `SELECT` query runs for each insert individually, and at that time, the name `sales` only to the rows that are inserted, not the whole table.

To illustrate this, if we do the three inserts in a single statement: `INSERT INTO sales (product, amount) VALUES ('apple', 30), ('apple', 40), ('banana', 60);`, then both products end up in the `top_sales` view. (but I'm not sure if this behaviour is guaranteed or if ClickHouse could split the data in batches if more records are inserted at once)

I think ClickHouse should have made this more explicit, for example by requiring the user to name the source table explicitly, and then refer to the inserted data by an `inserted` alias, similar to triggers in MSSQL:

```
CREATE MATERIALIZED VIEW top_products (product String, amount Int32) ORDER BY amount
FROM sales
AS
    SELECT product, SUM(amount) as amount
    FROM inserted
    GROUP BY product
    HAVING SUM(inserted.amount) > 50;
```


## B.2) A materialized view is NOT just an insert trigger
This needs [Kafka](https://kafka.apache.org/) setup and listening on port 9092.

```
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
```

Just when I thought I got the hang of it...

We can send events to Kafka by inserting record into a table with the Kafka engine, and I wanted to keep track of the events sent by Clickhouse. So I added a materialized view and expected it to work like an insert trigger here as well, copying each event into a separate table.

It turns out that on a Kafka table, creating a materialized view causes ClickHouse to subscribe as a Kafka consumer in the consumer group. So a materialized view is _not_ just an insert trigger. It depends on the table engine.

(run `kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic my_message` to watch incoming events, records inserted into the table (`INSERT INTO kafka(id, message) VALUES (1, 'hello');`) should appear as json in the consumer window)



## B.3) Materialize view column names have to match exactly
```
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
```

This code has a small error: the second column is called `amount` in the view's declaration, but we forgot to name it in the select statement. This means it will be called `SUM(amount)` in the query result.

Strangely, this is not an error, but results in 0 values being inserted for `amount` (or whatever the default value is for the column's datatype).

Columns are matched by name: selecting the right names, but in reverse order does work.

I can see how this can be convenient in some situations, for example if multiple views feed into a single target table, filling different columns. But still, I would prefer ClickHouse to be a bit stricter and require us to write out 0 columns in that case, or at least make it an error when the `SELECT` produces a column that doesn't match any target column.



# TTL (time to live)

A TTL can be set on tables to automatically discard records after a certain time expires.

## C.1) Conditional TTL on aggregated columns is dangerous
```
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
```

In this example we're counting events per day using a SummingMergeTree. After a month, we want to forget about events that happened less than 50 times a day.

Remember A.3: "Merges may NEVER happen". The problem here is that the TTL only looks at individual records, and if ClickHouse decides not to merge them, it will delete the deadlock events because both records are below the threshold of 50.


Unfortunately I can't find a way to make this example deterministic. Stopping merges before the insert makes sure they're not merged immediately. But we need to resume merges because materializing the TTL is also blocked by this setting.

In all my tests, the deadlock records get deleted, which is what we want to illustrate here, but if ClickHouse decides to merge these records before applying the TTL, they would remain.



## C.2) Different TTLs are not necessarily processed in order
```
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
```

One of my attempts to get around the problem above, was to add a second TTL rule. TTLs can do more than just delete. They can also be used to group data after some time expires, or move it to a different storage.

In this case, the idea was to add another TTL rule that runs before the `DELETE`. The result of this `GROUP BY` rule would be to force the merge if it hasn't happened yet.

When I run this example on my system, right now, it demonstrates this solution doesn't work. ClickHouse seems to process the `DELETE` first and the deadlock records still disappear. But it did work in an earlier attempt when ClickHouse process the `GROUP BY` first, the 'deadlock' records are retained, and my test passed. Unfortunately it then failed in the CI build.



## C.3) TTL isn't processed very frequently
The previous example showed that when a table has two TTL rules, and they are both expired, we can't count on the order in which ClickHouse will process the rules.

In many scenarios, data is inserted continuously for events as they happen and the TTL is on the record's age. So if the two rules are set up some time apart, the first rule should be processed well before the second TTL expires.

This should work if we never need to insert old data, _and_ if the gap is large enough.

However, it's important to remember that by default, there is a minimum time of [4 hours](https://clickhouse.com/docs/en/guides/developer/ttl) between TTL runs. So if the two rules are, for example, only two hours apart, this would only work for half the cases.



# SummingMergeTree columns
The Summing- and AggregatingMerge engines can be very useful for efficiently collecting aggregated data over large datasets, but some details can be a bit unexpected.

## D.1) Non-aggregated columns in a SummingMergeTree
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree() PRIMARY KEY id;
INSERT INTO person (id, name, score) VALUES (1, 'Alice', 10);
INSERT INTO person (id, name, score) VALUES (1, 'Bob', 15);
-- This shows Alice with a score of 25
SELECT * FROM person FINAL;
```

The SummingMergeTree engine does exactly what the name suggests: it sums up numeric columns, grouped by the primary key.

The result of the aggregation here will be the sum of the scores for the `score` column, as expected. For the name, I get 'Alice'. I think ClickHouse just keeps the first value, but I'm not sure if that behaviour is guaranteed.

Coming from a 'normal' database background it's hard to imagine how this behaviour, neither grouping or aggregating, but just returning any value, can be useful. But in ClickHouse it's much more common to have denormalised data. One use case could be when we know all values will be the same within our group. For example if we're aggregating something by IP address, and also want to store a subnet column.

Still, I would prefer if ClickHouse forced us to be explicit about this, for example by requiring that columns be marked as `any()` if they are neither being summed up or in the primary key, because it may not be what you intended, as shown in the next example:



## D.2) Adding columns to a SummingMergeTree with an explicit column list
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree(score) PRIMARY KEY id;
-- Some time passes, and we add a 'games' column to count the number of games played
ALTER TABLE person ADD COLUMN games Int32;
INSERT INTO person (id, name, score, games) VALUES (1, 'Alice', 10, 1);
INSERT INTO person (id, name, score, games) VALUES (1, 'Bob', 15, 1);
-- This shows Alice with a score of 25, and ONE game played, NOT two.
SELECT * FROM person FINAL;
```

Here we've created the same table, but this time we explicitly specified we want to sum up the `score` column: `SummingMergeTree(score)`.
Later, a second numeric column was added, but this will not be aggregated because `games` isn't in the list, and unfortunately we can't [easily change](https://github.com/ClickHouse/ClickHouse/issues/3054) it [after](https://github.com/ClickHouse/ClickHouse/issues/15278) the table is created.

If we replace `SummingMergeTree(score)` with just `SummingMergeTree` in the example above, it works as expected, but there can be valid reasons for not aggregate all numeric columns, so again, it would be nice if ClickHouse would force us to explicitly acknowledge the new column will not be aggregated.

It doesn't, even in situations where it should be abundantly clear to ClickHouse that this is not what we want:
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String, score Int32)
ENGINE = SummingMergeTree(score) PRIMARY KEY id;
-- Some time passes, and we add a 'games' column to count the number of games played
-- This time using AggregateFunction, so it should be very clear we want aggregation
ALTER TABLE person ADD COLUMN games AggregateFunction(count);
INSERT INTO person (id, name, score, games) SELECT 1, 'Alice', 10, countState();
INSERT INTO person (id, name, score, games) SELECT 1, 'Bob', 15, countState();
-- This still shows Alice with a score of 25, and ONE game played, NOT two.
SELECT id, name, score, finalizeAggregation(games) AS games FROM person FINAL;
```

AggregateFunction columns are a bit more complicated to use, but they support a very wide range of statistical aggregations. Unfortunately

Unfortunately, even though we're using an AggregateFunction column, nothing gets aggregated and the result will be whatever value was first inserted.



# SYSTEM STOP MERGES
Stopping merges is a bit of a niche feature in that's probably of limited use in production, but can be useful for setting up test cases.

Its behaviour also surprised me a number of times, and all of these surprises cost me time while writing tests.



## E.1) SYSTEM STOP MERGES also stops OPTIMIZE TABLE
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- Error.
OPTIMIZE TABLE person FINAL;
```

I discovered the `SYSTEM STOP MERGES` setting while writing a unittest for a case where I didn't want ClickHouse to automatically merge in the background. My (incorrect) mental model was that `SYSTEM STOP MERGES` would only stop background merges, and that explicitly telling it to `OPTIMIZE TABLE` would still work.

It doesn't, and using a normal ReplacingMergeTree we immediately get an error: `DB::Exception: Cancelled merging parts. (ABORTED)`. Not what I expected, but pretty clear, if it wasn't for the next point:



## E.2) SYSTEM STOP MERGES has a different effect on Replicated tables
```
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
```

Unfortunately my code was running a cluster, using one of the `Replicated-` versions of the engine. Doing the same on a replicated table doesn't cause an error, but lets the query hang until you either kill it or turn on merges again through a different connection.



## E.3) Stopping merges on a table that doesn't exist, isn't an error?
```
DROP TABLE IF EXISTS person;
-- Table doesn't exist yet, but this doesn't give an error!
SYSTEM STOP MERGES person;
```

I made this mistake when writing one of the examples above. First DROP the old table. Then stop merges on a table that doesn't exist yet. Then CREATE the new table. A stupid mistake, but easy to make, and surprisingly not an error!

For a moment I thought it may have added 'person' to an internal list of table names that shouldn't be merged, and that it would still work if I create the table later.

But that's not what happened:
```
-- And it doesn't work after the table is created
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- The merge just happens:
OPTIMIZE TABLE person FINAL;
SELECT * FROM person;
```

If we put things in the right order, the setting works correctly and the `OPTIMIZE TABLE` is rejected:

```
-- Now do things in the correct order:
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- Error.
OPTIMIZE TABLE person FINAL;
```



## E.4) `DELETE FROM` is a merge AND it also block for non-Replicated tables.
```
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
```

This is where things get really strange. We know ClickHouse doesn't really like deletes, and it turns out they actually count as merges.

Because the problem I wanted to solve involved some records that hadn't been merged, I had setup my test case with merges disabled. The fix I implemented included a `DELETE FROM`, and it took me a while to figure out why my code was hanging.

After thinking about this for a while it does make sense since records need to be modified, but it was unexpected. (gotcha!)

What annoys me is the inconsistency in this behaviour. For `OPTIMIZE TABLE`, MergeTrees just prints and error if merges are stopped, and the Replicated- versions block. This is already confusing, but to make it worse, they both block for `DELETE FROM`.

(there's also an asynchronous `ALTER TABLE DELETE` that does return when merges are disabled. It can be made synchronous by adding `SETTINGS mutations_sync=1`, which will make it block as well)



## E.5) SYSTEM STOP MERGES doesn't stop merges on bulk inserts
```
DROP TABLE IF EXISTS person;
CREATE TABLE person (id UInt32, name String) ENGINE = ReplacingMergeTree PRIMARY KEY id;
SYSTEM STOP MERGES person;
INSERT INTO person (id, name) VALUES (1, 'Alice');
INSERT INTO person (id, name) VALUES (1, 'Bob');
-- These two records still get merged
INSERT INTO person (id, name) VALUES (2, 'Charles'), (2, 'Dylan');
SELECT * FROM person;
```

How many points can I make about `SYSTEM STOP MERGES`? Well one more that also bit me while writing a test:

I expected to see 4 records here, since we set `SYSTEM STOP MERGES person`. But it turns out ClickHouse _does_ aggregrate the data, when it's inserted in a single insert batch.

In this case, this results in two separate records for id 1, but just one for id 2.






# Work in progress!

Feel free to contribute :-)

