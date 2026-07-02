# Purpose: Cleans raw telemetry CSV, reprojects coordinates to Swiss LV95, 
#          and filters out animals with less than 30 days of data per season.

#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(lubridate)
  library(sf)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop("Usage: Rscript 01_preprocess_basic.R <input_csv> <output_gpkg>")
}

input_csv  <- args[1]
output_gpkg <- args[2]

# ---- read raw csv ----
raw_data <- read_delim(input_csv,
                    delim = ";",
                    col_types = cols())  # ; as delimiter

# ---- select columns ----
selected_cols <- raw_data %>%
  select(
    timestamp,
    id,
    Height_m,
    DOP,
    FixType,
    Temp_C,
    latitude,
    longitude,
    Jahreszeit,
    Halbjahr,
    daytime
  )

# ---- timestamp to POSIXct with timezone ----
selected_cols <- selected_cols %>%
  mutate(
    timestamp = ymd_hms(timestamp, tz = "UTC"),
    timestamp = with_tz(timestamp, tzone = "Europe/Zurich")
  )

# ---- create sf object in WGS84 ----
raw_sf <- st_as_sf(
  selected_cols,
  coords = c("longitude", "latitude"),
  crs = 4326,
  remove = FALSE
)

# ---- reproject to LV95 (EPSG:2056) ----
raw_sf_2056 <- st_transform(raw_sf, 2056)

# optional: extract x/y if you want them as columns
raw_sf_2056 <- raw_sf_2056 %>%
  mutate(
    x = st_coordinates(geometry)[, 1],
    y = st_coordinates(geometry)[, 2]
  )

# ---- simple summer/winter filter ----
#   - "Jahreszeit" already encodes seasons (e.g., "Sommer", "Winter")
#   - At least 30 days of data in each season per animal

season_summary <- raw_sf_2056 %>%
  mutate(date = as_date(timestamp)) %>%
  group_by(id, Jahreszeit) %>%
  summarise(
    n_days = n_distinct(date),
    .groups = "drop"
  )

valid_ids <- season_summary %>%
  filter(Jahreszeit %in% c("Sommer", "Winter")) %>%
  group_by(id) %>%
  summarise(
    has_summer = any(Jahreszeit == "Sommer" & n_days >= 30),
    has_winter = any(Jahreszeit == "Winter" & n_days >= 30),
    .groups = "drop"
  ) %>%
  filter(has_summer, has_winter) %>%
  pull(id)

filtered_sf <- raw_sf_2056 %>%
  filter(id %in% valid_ids)

# ---- write to GeoPackage ----
st_write(filtered_sf, output_gpkg, delete_dsn = TRUE)
