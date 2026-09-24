-- ============================================================
-- Chicago Rideshare Nightlife Signature Analysis
-- Source: City of Chicago Data Portal, Transportation Network Providers - Trips
-- Platform: Google BigQuery
--
-- Note: the query that produced the 7,607 minimum-trip threshold was run
-- interactively and not saved. Step 3 below reproduces the same calculation;
-- because APPROX_QUANTILES is approximate, a later rerun returned 7,713.
-- The analysis uses the original 7,607 cutoff.
-- ============================================================


-- ============================================================
-- STEP 1: Choose the geographic key
-- Compare fill rates for census tract vs. pickup coordinates.
-- The city suppresses geography on some trips for privacy, so the field
-- with better coverage loses fewer trips (and less non-random bias).
-- Result: 62.5% have census tract, 90.8% have coordinates -> use coordinates.
-- ============================================================

-- 1a. Census tract fill rate
select
  count(*) as total_rows,
  countif(pickup_census_tract is not null) as tract_present,
  round(countif(pickup_census_tract is not null) / count(*) * 100, 1) as pct_with_tract
from `chicago-rideshare-analysis.port_tnp_project.trips_25`
where trip_start_timestamp like '%/2025 %';

-- 1b. Pickup coordinate fill rate
select
  count(*) as total_rows,
  countif(pickup_centroid_latitude is not null) as latlong_present,
  round(countif(pickup_centroid_latitude is not null) / count(*) * 100, 1) as pct_with_latlong
from `chicago-rideshare-analysis.port_tnp_project.trips_25`
where trip_start_timestamp like '%/2025 %';


-- ============================================================
-- STEP 2: Build the analysis table
-- Parse text timestamps into real timestamps (needed for EXTRACT later),
-- SAFE_CAST numeric fields so a single bad value returns null instead of
-- failing the query, and round pickup coordinates to 3 decimals to create
-- grid cells. Keep 2025 trips that have pickup coordinates.
-- Result: 84,864,755 rows.
-- ============================================================

create or replace table `chicago-rideshare-analysis.port_tnp_project.full_trips_fin` as
select
  trip_id,
  parse_timestamp('%m/%d/%Y %I:%M:%S %p', trip_start_timestamp) as trip_start,
  parse_timestamp('%m/%d/%Y %I:%M:%S %p', trip_end_timestamp) as trip_end,

  safe_cast(trip_seconds as int64) as trip_sec,
  safe_cast(trip_miles as float64) as miles,
  safe_cast(trip_total as float64) as total_cost,

  -- community areas (kept for future dropoff-side analysis)
  safe_cast(pickup_community_area as int64) as pickup_area,
  safe_cast(dropoff_community_area as int64) as dropoff_area,

  -- grid cells for tighter location analysis
  round(safe_cast(pickup_centroid_latitude as float64), 3) as pickup_lat_grid,
  round(safe_cast(pickup_centroid_longitude as float64), 3) as pickup_lon_grid

from `chicago-rideshare-analysis.port_tnp_project.trips_25`
where
  trip_start_timestamp like '%/2025 %'
  and pickup_centroid_latitude is not null
  and pickup_centroid_longitude is not null;


-- ============================================================
-- STEP 3: Set the cutoffs used in Step 4
-- Percentiles are used instead of hand-picked values so that extreme
-- outliers (max trip distance is over 1,000 miles) don't move the cutoffs.
-- ============================================================

-- 3a. Trip-distance quartiles -> short/medium/long cutoffs
-- Result: [0.0, 1.9, 3.9, 8.4, 1264.3] -> 25th = 1.9 mi, 75th = 8.4 mi.
-- Identical quartiles on an earlier sample table, so the cutoffs are stable.
select
  min(miles) as min_miles,
  max(miles) as max_miles,
  avg(miles) as avg_miles,
  approx_quantiles(miles, 4) as quartiles
from `chicago-rideshare-analysis.port_tnp_project.full_trips_fin`;

-- 3b. Trips-per-cell quartiles -> minimum-trip threshold
-- Cells with very few trips produce unstable percentages, so the bottom
-- quarter of cells is excluded. Analysis uses 7,607 (see note at top).
select approx_quantiles(total_trips, 4) as trip_count_quartiles
from (
  select
    pickup_lat_grid,
    pickup_lon_grid,
    count(*) as total_trips
  from `chicago-rideshare-analysis.port_tnp_project.full_trips_fin`
  group by pickup_lat_grid, pickup_lon_grid
);


-- ============================================================
-- STEP 4: Main analysis
-- Label every trip by time of day, weekend/weekday, and distance.
-- Compare each grid cell's share of late-night, weekend, and short trips
-- against the citywide share. The difference (in percentage points) is the
-- cell's "deviation" — how unusual that cell is compared to the city overall.
-- Output: 659 cells ranked by nightlife score.
-- ============================================================

with labeled_trips as (
  select
    pickup_lat_grid,
    pickup_lon_grid,
    case
      when extract(hour from trip_start) between 6 and 11 then 'morning'
      when extract(hour from trip_start) between 12 and 16 then 'afternoon'
      when extract(hour from trip_start) between 17 and 20 then 'evening'
      else 'late_night'  -- 9 p.m. through 5:59 a.m.
    end as time_of_day_category,
    case
      when extract(dayofweek from trip_start) = 1
        or extract(dayofweek from trip_start) = 7 then 'weekend'  -- Sun, Sat
      when extract(dayofweek from trip_start) between 2 and 6 then 'weekday'
      else null
    end as day_of_week_category,
    case
      when miles <= 1.9 then 'short'
      when miles > 1.9 and miles < 8.4 then 'medium'
      when miles >= 8.4 then 'long'
      else null
    end as trip_distance_category
  from `chicago-rideshare-analysis.port_tnp_project.full_trips_fin`
),

-- citywide baseline: what share of ALL trips falls in each category
city_wide_perc as (
  select
    round(countif(time_of_day_category = 'morning') / count(*) * 100, 2) as pct_morning_city,
    round(countif(time_of_day_category = 'afternoon') / count(*) * 100, 2) as pct_afternoon_city,
    round(countif(time_of_day_category = 'evening') / count(*) * 100, 2) as pct_evening_city,
    round(countif(time_of_day_category = 'late_night') / count(*) * 100, 2) as pct_late_night_city,
    round(countif(day_of_week_category = 'weekend') / count(*) * 100, 2) as pct_weekend_city,
    round(countif(day_of_week_category = 'weekday') / count(*) * 100, 2) as pct_weekday_city,
    round(countif(trip_distance_category = 'short') / count(*) * 100, 2) as pct_short_city,
    round(countif(trip_distance_category = 'medium') / count(*) * 100, 2) as pct_medium_city,
    round(countif(trip_distance_category = 'long') / count(*) * 100, 2) as pct_long_city
  from labeled_trips
),

-- same percentages, but per grid cell
cell_by_cell as (
  select
    pickup_lat_grid,
    pickup_lon_grid,
    round(countif(time_of_day_category = 'morning') / count(*) * 100, 2) as pct_morning_cell,
    round(countif(time_of_day_category = 'afternoon') / count(*) * 100, 2) as pct_afternoon_cell,
    round(countif(time_of_day_category = 'evening') / count(*) * 100, 2) as pct_evening_cell,
    round(countif(time_of_day_category = 'late_night') / count(*) * 100, 2) as pct_late_night_cell,
    round(countif(day_of_week_category = 'weekend') / count(*) * 100, 2) as pct_weekend_cell,
    round(countif(day_of_week_category = 'weekday') / count(*) * 100, 2) as pct_weekday_cell,
    round(countif(trip_distance_category = 'short') / count(*) * 100, 2) as pct_short_cell,
    round(countif(trip_distance_category = 'medium') / count(*) * 100, 2) as pct_medium_cell,
    round(countif(trip_distance_category = 'long') / count(*) * 100, 2) as pct_long_cell,
    count(*) as total_trips
  from labeled_trips
  group by pickup_lat_grid, pickup_lon_grid
),

-- cell share minus citywide share = deviation in percentage points
-- CROSS JOIN attaches the single citywide row to every cell row
big_table as (
  select *,
    pct_late_night_cell - pct_late_night_city as late_night_dev,
    pct_weekend_cell - pct_weekend_city as weekend_dev,
    pct_short_cell - pct_short_city as short_dev
  from cell_by_cell
  cross join city_wide_perc
),

-- combined score: average of the three deviations
night_dev as (
  select *,
    (late_night_dev + weekend_dev + short_dev) / 3 as night_life_score
  from big_table
)

select *,
  rank() over (order by night_life_score desc) as night_rank
from night_dev
where total_trips >= 7607
order by night_rank;
