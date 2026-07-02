#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(purrr)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop("Usage: Rscript 03_nsd_classification.R <input_gpkg> <output_csv>")
}

input_gpkg  <- args[1]
output_csv <- args[2]

cat("Loading data...\n")
gdf <- st_read(input_gpkg, quiet = TRUE)

# Force numeric columns
gdf <- gdf %>%
  mutate(
    x = as.numeric(x),
    y = as.numeric(y),
    # z = as.numeric(z)
  )

# Ensure ordering
gdf <- gdf %>% arrange(id, timestamp)

# Helper: compute MSD for one individual
compute_nsd <- function(df) {
  n <- nrow(df)

  # --- choose winter anchor date ---
  anchor_dates <- c("02-01", "01-01", "12-01", "11-01")

  df$md <- format(df$timestamp, "%m-%d")

  anchor_row <- NULL
  for (ad in anchor_dates) {
    tmp <- df[df$md == ad, ]
    if (nrow(tmp) > 0) {
      anchor_row <- tmp[1, ]
      break
    }
  }

  # fallback: first row
  if (is.null(anchor_row)) {
    anchor_row <- df[1, ]
  }

  # --- extract reference coordinate ---
  ref <- anchor_row %>%
    st_drop_geometry() %>%
    select(x, y) %>%
    mutate(across(everything(), as.numeric)) %>%
    as.matrix()

  
  coords <- df %>%
    st_drop_geometry() %>%   # VERY important for sf objects
    select(x, y) %>%
    mutate(across(everything(), as.numeric)) %>%
    as.matrix()

  diffs <- sweep(coords, 2, ref, "-")
  nsd_vals <- rowSums(diffs^2)

  tibble(
    id = df$id[1],
    t = seq_len(nrow(df)),
    nsd = nsd_vals
  )
}

cat("Computing NSD curves...\n")
nsd_list <- gdf %>%
  group_split(id) %>%
  map(~ compute_nsd(.x) %>% mutate(id = unique(.x$id)))

nsd_df <- bind_rows(nsd_list)
readr::write_csv(nsd_df, "nsd_curves.csv")


cat("Done.\n")
