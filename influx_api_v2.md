# InfluxDB API Redesign

Now that we have experience with people using InfluxDB and more feedback from the community around use cases, I wanted to put together some thoughts on the requirements as I see them and potential ways to structure the API going forward to best meet those requirements.

## Goals

First, let's start with some general goals of the project. People usually take these three goals as a given, but I list them here at the top just to show their importance in this project.

1. Ease of use. The API should be easy to understand and it should push people in the right direction. If the default behavior yields surprising results, we've failed.
2. Performance. Given the use cases I outline later in this document, fast performance is a requirement. This goes together with ease of use. Bad performance is a surprising result and means we've failed not only with this requirement, but requirement #1.
3. Scalability. We should be able to support millions of separate time series (if modeled like Graphite), or thousands of metrics with tags that have cardinality in the tens of thousands (if modeled like OpenTSDB).

Now these requirements are pretty loose. I can already see @jvshahid shaking his head at me because they're non-specific. Like, what kind of performance guarantees are we talking about here? What does ease of use mean? Easy for whom?

These are ongoing goals of the project that should be improved over time. They'll never be done because any of these three can always find room for improvement. They're just something to keep in mind when doing any work.

Ok, now onto some use cases.

## Use Cases

There are three different use cases that crop up most often with people using or interested in using InfluxDB:

1. DevOps data - what happens on servers, in their applications, etc.
2. Sensor data - IoT, industrial applications, power, etc.
3. Real-time user/business analytics - Counting page views, unique user counts, funnels, and more

When querying this data the work is usually centered around either _discoverability_ or _computations on specific series_.

### Discoverability

Discoverability is all about finding out what time series exist for given periods of time. Here are some example questions one might ask:

* Which data centers exist?
* For a given data center, which hosts reported CPU in this hour?
* For cpu, given data center 1, which hosts reported a load > 90%?
* Which devices haven't reported temp in the last day?

Discoverability could be a query about metadata like what hosts have I seen in the last hour, or it could be something that requires some sort of computation like, what hosts have memory usage > 80% in the last hour. The first question only looks at metadata, while the second would require meta data lookup (which hosts exist) and then a computation against all the appropriate time series.

### Computation on series

Computation on series could be aggregate functions like `min`, `max`, `greaterThan`, etc. But it can also require combining or morphing series by either normalizing them with values at given time intervals, applying a function like derivative on the series, merging multiple series together and performing a computiation against the result, dividing one by another, or doing any number of these things on many series.

## Existing approaches

Many people are coming from either a Graphite or OpenTSDB background. Some are coming from an experience of rolling their own solution on top of Cassandra or MongoDB. First, I'll talk about how Graphite and OpenTSDB frame these problems and then I'll dig into some requirements and thoughts on how Influx should be designed.

The graphite method of representing time series data is to have many series and to encode the metadata in the series names. Each series only has a single value and all series have an underlying assumption of some data collection interval (like once every 10s). For instance, if you have a server in a data center with a cpu idle: `hosta.dc1.cpu.idle` Or if you have a temperature sensor on a device: `device1.temp`.

These names can quickly get quite large. Graphite's method of drilling down on these metrics is heirarchical. That's how discovery works. You can then merge series together or perform functions against a few of them. You never need to specify what value you're working with because it's in the series name and each series only has one set of values (as opposed to columns).

OpenTSDB uses the concept of tags. In our previous example you'd have `metrics` called `cpu.idle` and `temp` respectively. The metadata of which data center, server, or device you're looking at is kept as a "tag".

Personally, I find the tag method of working with things a bit nicer. People are often using InfluxDB columns like this. The only problem is that you can quickly get into a situation where performance is very poor.

Something these two approaches have in common is that there is only a single value given a series name (in graphite) or a metric and a set of tags (in OpenTSDB). I believe this makes things simpler for graphing and monitoring libraries. They always know what it is they're going to be mapping.

## InfluxDB's design

The requirements that follow this section will use the language defined here. These are some ideas on the design of the InfluxDB API. Note that these are just ideas for the next version of the API. Feedback and modifications are welcome!

### Shard Spaces

I want to throw out the idea of shard spaces. Their entire purpose was to handle two things: replication factor and retention policy. Shard spaces as a user facing API concept is too close to how things are implemented under the hood. Instead, we'll simply define retention policies and their replication factors.

```json
{
  "name": "1_week",
  "retention": "7d",
  "replicationFactor": 2
}
```

This looks very similar to the shard space definition. However, notice that we don't have split, shard duration, or (most importantly) the regex to match against the series name. Instead, databases will have a default retention policy that all writes go into. A database definition:

```json
{
  "name": "paulDB",
  "retentionPolicies": [
    {
      "name": "1_week",
      "retention": "7d",
      "replicationFactor": 2
    }
  ],
  "defaultRetentionPolicy": "1_week"
}
```

Notice that the retention policies are part of the database definition. The default retention policy is what all writes will go into, unless otherwise specified at the time of the write. The same is true for any queries issued against the database. By default it will issue the query against the default retention policy.

This makes the assignment to a retention policy explicit, which was something in shard spaces that was causing a great deal of confusion for users. Obviously, this means that the retention policy is something that will have to be exposed in the query language.

Before moving onto that, I'd like to address data types, columns, and how things are structured.

### Columns, data types, and tags

By watching people use Influx over the last 6 months, I've seen a number of repeated questions and we're starting to see some of regular usage patterns. I'd like those represented in the structure of the database and the API. The simplicity of Graphite and OpenTSDB's single value per series makes things like graphing and monitoring easier (at least it seems that way). I'd like to do that with Influx, but still keep our flexibility to do some of the other things people do.

Here are a few ideas aound how to structure things:

Every series has the following new special columns: `bool`, `double`, `string`, `bytes`. The type of each of those columns is the same as its name implies. Another option I'm thinking of is that every series only has a single special column called `value` and the type is determined by whatever the first thing written into that column is. Any future writes that try to write a different type will throw an error. Not sure yet which approach is best, but hopefully by writing more of this up it will become self-evident.

Series still have the old special columns of `time` and `sequence_number`. However, sequence number is now an optional column that isn't present by default. If users want `sequence_number` assigned, which you'd only want if there's a chance two data points could have the same `time`, it should be specified when the series is created. In addition `name` and `retention` are now a reserved column names.

All other columns for a series are considered tags. That is, they're strings that will be indexed. This means if you're putting unstructured data into a column, it should only ever go into the special `string` and `bytes` column. That also means that any given series can only have those two columns of unstructured non-indexed data.

By default, all series will be indexed by the union of their column values. Here's an example:

```json
{
  "name": "cpu_load",
  "dataCenter": "USWest",
  "host": "serverA.influxdb.com",
  "double": 68
}
```

Now say we want to do a query against this data:

```sql
select mean() from cpu_load
where dataCenter = 'USWest' and 
  host = 'serverA.influxdb.com' and
  time > now() - 4h
group by time(5m)
```

Notice in this query that we didn't specify the column that mean would run against. For this function we already know, it's going to be the double column. Other functions like `count` will assume the double column by default, but other columns could be counted instead. Basically, all functions will run by default against the `double` column unless told otherwise.

Now let's get the mean across a data center:

```sql
select mean() from cpu_load
where dataCenter = 'USWest' and 
  time > now() - 4h
group by time(5m)
```

I'll have to get into the underlying details of how things work to show how this query is answered. Even though that's not really user facing API, it's important to know what the performance impliciations of different structures are. First, to answer this query, as with any query, we have to lookup what columns exist for the given series on the given time range.

For the first example query, we looked up `cpu_load` and saw that there were two columns and we where matching against both. 

For the second query, we lookup the `cpu_load` series and see that the `dataCenter` and `host` columns exist. However, in this query we're only specifying the `dataCenter` column. So we have to look up what values exist for the `dataCenter` column on the `cpu_load` series for the last 4 hours. If we find 30 hosts we have to then expand that query in to 30 seperate queries that get merged together.

That means that by deafult, the tuple `(series, column1, column2, column3, ...)` defines four separate series, one for each special column: `bool`, `double`, `string`, and `bytes`. In our example, we have a series of doubles `(cpu_load, USWest, serverA.influxdb.com)`.

This seems like it's going to be a problem if we have thousands of hosts in a data center and we're often performing a query across the datacenter.

#### Indexes

We'll have to do some performance testing to see how queries work that end up merging thousands of series. My guess is we'll want to have indexes that denormalize the data. So not totally like indexes under the hood.

```sql
create index cpu_load_dataCenter
ON cpu_load (dataCenter)
```

Now, when a write goes into `cpu_load` it will actually get expanded into writes for the default series `(cpu_load, USWest, serverA.influxdb.com)` and the index series. My thought is it would create a new series for `(cpu_load, USWest)` and that would have two ranges: one for the double values, and one for the non-indexed column data. For example if we wrote:

```json
{
  "double": 68,
  "dataCenter": "USWest",
  "host": "serverA.influxdb.com"
}
```

We'd have three writes occur on the underlying database: one double for the `(cpu_load, USwest, serverA.influxdb.com)` series, one double for the `(cpu_load, USWest)` series, and one column blob for the `(cpu_load, USWest)` series where the value is a set of unique value ids: `[1]` where 1 = serverA.influxdb.com. If the metadata is new, we'll have to do writes for that too.

Of course, this is something we'll have to performance test across a number of use cases. How do queries perform when the cardinality of a column is 10, 100, 1,000, 10,000, 100,000, 1,000,000, and 10,000,000?

### Metadata Indexes

As mentioned earlier in this document, to answer queries we have to look up metadata properties on series. We need to be able to answer for each shard:

* Given a series name, what columns exist?
* Given a series name and column, what values exist?

We will probably want to filter this down further based on the shard size. For instance, if it's 1-7 days, have the indexes exist on a per hour basis in the shard. That way we can answer metadata queries that have time constraints. At least approximately.

## Writes

Now that we have the different column types defined and retention policies, we can show how to write data in. One assumption this write structure makes is that we often have a set of measurements comming from something where the metadata is the same, and the measurements are across different sensors.

Here's the most basic non-compact representation. Post data like this:

```json
[
  {
    "name": "cpu_load",
    "values" : [
      {
        "double": 89.0,
        "dataCenter": "USWest",
        "host": "serverA",
        "time": 1412689241000
      }
    ]
  }
]
```

As usual, time can be ommitted and it will get assigned automatically by InfluxDB. Any attribute in values can be pulled out into the upper map:

```json
[
  {
    "name": "cpu_load",
    "values" : [
      {
        "double": 89.0,
      }
    ],
    "time": 1412689241000,
    "dataCenter": "USWest",
    "host": "serverA",
  }
]
```

Or you can have sequence numbers assigned to ensure that you can have two events at the same time stamp:

```json
[
  {
    "name": "events",
    "values" : [
      {
        "bool": true,
        "userId": "1",
        "type": "click",
        "button": "someThing",
      }
    ]
    "sequence_number": true
  }
]
```

Or posting to multiple series at the same time:

```json
[
  {
    "values" : [
      {
        "name": "cpu_load",
        "double": 89.0,
      },
      {
        "name": "cpu_wait",
        "double": 5
      }
    ],
    "time": 1412689241000,
    "dataCenter": "USWest",
    "host": "serverA",
  }
]
```

Or writing into a given retention policy:

```json
[
  {
    "name": "exceptions",
    "values" : [
      {
        "string": "some stack trace",
        "controller": "Users",
        "action": "Show",
      }
    ]
    "sequence_number": true,
    "retention": "forever"
  }
]
```

The above assumes that you've created a retention policy named "forever" for the given database. It will throw an error otherwise.

As you can see from the examples, the top level elements of the map can be pulled into the values themselves and visa-versa. This makes it easy to post many values at the same time without repeating shared metadata.

You can also post multiple maps in a single request.

## Example Queries

Throwing out some example queries to show how to answer different kinds of questions.

### Getting the tags and tag values for a series

```sql
-- get the list of tags that have appeared for a series
select tags(cpu_load)

-- get the list of tags that have appeared for a series limited by time
select tags() from cpu_load where time > now() - 1h

-- get the list of columns for multiple series. would return two series
select columns() from cpu_load, cpu_wait

-- selects from the default retention period
select distinct(host) from cpu_load

-- selects from the 6_months retention period
-- the . is a separator between the 
select distinct(host) from 6_months.cpu_load

-- wrap in quotes for special characters
select distinct(host) from "6 months"."cpu.load"

-- it's always better for the user to specify a time frame, otherwise we have to check every shard
select distinct(host) from cpu_load where time > now() - 1h

-- filter by some other column value
select distinct(host) from cpu_load
where time > now() - 1h and data_center = 'USWest'

-- find out how many tag combinations (and thus series)
-- there are for a given name
select count(distinct(columns())) from cpu_load

-- find out how many tag combinatios filtered by one tag
select count(distinct(availability_zone, host)) from cpu_load
where region = 'us-east'
```

From those examples you can see that *names* and *columns* can be wrapped in double quotes in any query to make it possible to have special characters.

This also shows the ability to do a faceted drilldown on column values for a given series. The distinct function would need to be able to take a list of column names that is checks for uniqueness across.

### Querying series

Here are some example queries

```sql
-- see which series names exist in the default retention policy. In this new model, the number of 
-- names should be much smaller. Probably on the order of a few hundred to a few thousand
list names

-- or see the names for a given retention policy
list names for 6_month
-- or with special characters
list names for "6 month"

-- assume cpu_load has data_center and host and no other columns
-- get a single series
select double from cpu_load
where data_center = 'us-west' and host = 'serverA' and
  time > now() - 1h

-- downsample on the fly from a raw series
select mean() from cpu_load
where data_center = 'us-west' and host = 'serverA' and
  time > now() - 24h
group by time(10m)

-- select the mean from multiple series
-- downsample on the fly from a raw series
select mean() from cpu_load, cpu_wait
where data_center = 'us-west' and host = 'serverA' and
  time > now() - 24h
group by time(10m)
/* would result in two series returned
[
  {
    "name": "cpu_load",
    "columns": ["mean", "time"],
    "values": [...]
  },
  {
    "name": "cpu_wait",
    "columns": ["mean", "time"],
    "values": [...]
  }
]
*/

-- or select different aggregates from mutiple series
-- the 'double' column is the default so we don't have to specify
select mean(cpu_load), max(cpu_load), max(cpu_wait)
from cpu_load, cpu_wait
where data_center = 'us-west' and host = 'serverA' and
  time > now() - 24h
group by time(10m)

-- query by regex
select string from log_lines
where string =~ /error/i
  and time > now() - 4h

-- query against columns on regex
select string, application from log_lines
where application =~ /^ruby.*/
  and time > now() - 1h

-- merge all hosts from a given data_center and downsample
select mean() from cpu_load
where data_center = 'us-west' and
  time > now() - 24h
group by time(10m)

-- output separate points per uniuqe host id
select mean() from cpu_load
where data_center = 'us-west' and
  time > now() - 24h
group by time(10m), host

-- expand into multiple series. Saves space not repeating column values.
-- this is also closer to what people actually want when graphing or working with data.
select mean() from cpu_load
where data_center = 'us-west' and
  time > now() - 24h
group by time(10m)
expand by host
/* returns something like
[
  {
    "name": "cpu_load",
    "sharedColumns": {
      "host": "serverA"
    },
    "columns": ["mean", "time"],
    "values": [[23.2, 1412689241000], [19.0, 1412689231000]]
  },
  {
    "name": "cpu_load",
    "sharedColumns": {
      "host": "serverB"
    }
    "columns": ["mean", "time"],
    "values": [...]
  }
]
*/

-- expanding out into all series for a name
selelct mean() from cpu_load
where time > now() - 1h
group by time(1m)
expand by columns()

-- merging separate series. I'm not sure if this is useful in any way
select mean() from merge(cpu_load, cpu_wait)
group by time(10m)
where data_center = 'us-west' and host = 'serverA'
  and time > now() - 24h
/* return something like
[
  {
    "name": "cpu_load AND cpu_wait",
    "columns": ["mean", "time", "name"],
    "values": [[23.2, 1412689241000, "cpu_load"], [1.1, 1412689241000, "cpu_wait"], ...]
  }
]
*/

-- getting the top cpu load hosts
select double from cpu_load
where data_center = 'us-west' and time > now() - 1h
order by double desc
limit 10

-- or get the top cpu load hosts from downsample
select mean() from cpu_load
where data_center = 'us-west' and time > now() - 8h
group by time(5m)
order by mean desc
limit 10

-- so order by and limit get applied after any group
-- by time perid constructs the series.
-- If an order by is given, it means the entire series
-- will be loaded into memory, so we'll have to be careful.
```

### Continuous queries

I think changing the continuous query syntax slightly is a good idea. We'll have to do that anyway for the retention policy stuff.

```sql
-- a continous query to downsample from the default retention
-- into a longer term retention. Will create new series there
-- with the column data carried over
select mean() from cpu_load
group by time(1h)
expand by columns()
continuously into "6_month"."cpu_load"

-- and chain it: obviously the mean is now a mean of means.
-- Don't worry, the ends justify it.
select mean() from 6_month.cpu_load
group by time(1d)
expand by columns()
continuously into "3_years"."cpu_load"
```

## Potential things to deprecate

The as keyword seems like it's not really necessary with this new structure.

