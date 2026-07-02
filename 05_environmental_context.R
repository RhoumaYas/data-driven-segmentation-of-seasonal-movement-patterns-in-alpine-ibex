#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(sf)
  library(readr)
  library(terra)
  library(dplyr)
  library(tidyr)
  library(data.table)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 5) {
  stop("Usage: Rscript 05_environmental_context.R <input_clustered_gpkg> <dem_25m_tif> <arealstatistik_gpkg> <buffer_meters> <output_gpkg>")
}

input_gpkg       <- args[1]
dem_path         <- args[2]
landuse_path     <- args[3]
buffer_dist      <- as.numeric(args[4])
output_path      <- args[5]

cat("Loading path clusters...\n")
pts <- st_read(input_gpkg, quiet = TRUE)
pts$row_id <- seq_len(nrow(pts))

# Isolate migration coordinates
moving_pts <- pts %>% filter(state == -1) %>% arrange(id, row_id)

# Structuring continuous trajectories
cat("Building geometric flight corridors...\n")
moving_pts <- moving_pts %>%
  group_by(id) %>%
  mutate(
    new_segment = c(TRUE, diff(row_id) > 1),
    segment_local = cumsum(new_segment) - 1
  ) %>%
  ungroup() %>%
  mutate(
    segment_id = cumsum(c(TRUE, 
                          id[-1] != id[-n()] |
                          segment_local[-1] != segment_local[-n()])) - 1
  ) %>%
  select(-new_segment, -segment_local)

# Generate path links and buffers
step_buffers <- moving_pts %>%
  group_by(segment_id) %>%
  group_split() %>%
  lapply(function(seg) {
    if (nrow(seg) < 2) return(NULL)
    coords <- st_coordinates(seg)
    out <- lapply(1:(nrow(seg) - 1), function(i) {
      line <- st_linestring(rbind(coords[i, ], coords[i + 1, ]))
      st_sf(
        id = seg$id[i],
        segment_id = seg$segment_id[i],
        row_id_1 = seg$row_id[i],
        row_id_2 = seg$row_id[i + 1],
        t1 = seg$timestamp[i],
        t2 = seg$timestamp[i + 1],
        geometry = st_sfc(line, crs = st_crs(seg))
      ) %>% st_buffer(buffer_dist)
    })
    do.call(rbind, out)
  })
step_buffers <- do.call(rbind, step_buffers)
step_buffers$Segment_ID_Key <- seq_len(nrow(step_buffers))

# Terrain parameter stack generation
cat("Processing terrain rasters...\n")
dem25 <- terra::rast(dem_path)
slope <- terra::terrain(dem25, "slope")
aspect <- terra::terrain(dem25, "aspect")
roughness <- terra::terrain(dem25, "roughness")
TRI <- terra::terrain(dem25, "TRI")

terrain_stack <- c(dem25, slope, aspect, roughness, TRI)
names(terrain_stack) <- c("elevation", "slope", "aspect", "roughness", "TRI")

# Zonal statistic continuous raster extraction
cat("Extracting continuous topographic variables...\n")
seg_vect <- terra::vect(step_buffers)
cont_extracted <- terra::extract(terrain_stack, seg_vect, weights = TRUE)

cont_stats <- cont_extracted %>%
  group_by(ID) %>%
  summarise(
    across(c(elevation, slope, aspect, roughness, TRI),
           ~ sum(.x * weight, na.rm = TRUE) / sum(weight, na.rm = TRUE)),
    .groups = "drop"
  )

# Land-use classification mapping
cat("Rasterizing Arealstatistik vectors...\n")
landuse <- st_read(landuse_path, quiet = TRUE)
r_template <- terra::rast(terra::ext(seg_vect), resolution = 100, crs = terra::crs(seg_vect))
r_as17 <- terra::rasterize(terra::vect(landuse), r_template, field = "AS_17")

# Class area weighted metric evaluation
seg_vect$weight <- terra::perim(seg_vect)
as17_cells_weighted <- terra::extract(r_as17, seg_vect, cells = TRUE)

weights_df <- data.frame(
  ID = seq_len(nrow(seg_vect)), 
  tier_id = seg_vect$id, 
  weight = seg_vect$weight
)

as17_stats_weighted <- as17_cells_weighted %>%
  left_join(weights_df, by = "ID") %>%
  group_by(tier_id, AS_17) %>% 
  summarise(total_weight = sum(weight, na.rm = TRUE), .groups = "drop") %>% 
  group_by(tier_id) %>% 
  mutate(prop = total_weight / sum(total_weight)) %>% 
  ungroup() %>% 
  mutate(AS_17 = paste0(AS_17, "_weighted")) %>% 
  pivot_wider(id_cols = tier_id, names_from = AS_17, values_from = prop, values_fill = 0)

# Join tables and format names
cat("Assembling unified output dataset...\n")
lu_names <- c(
  "industrie_gewerbe", "gebaeudeareal", "verkehrsflaechen", "siedlungs_sonderflaechen",
  "erholung_gruenanlagen", "obst_reb_gartenbau", "ackerland", "naturwiesen_heimweiden",
  "alpwirtschaft", "wald", "gebueschwald", "gehoelze", "stehende_gewaesser",
  "fliessgewaesser", "unproduktive_vegetation", "vegetationslose_flaechen", "gletscher_firn"
)
rename_map <- setNames(lu_names, as.character(1:17))

final_table <- step_buffers %>%
  left_join(cont_stats, by = c("Segment_ID_Key" = "ID")) %>%
  left_join(as17_stats_weighted, by = c("id" = "tier_id"))

cols_to_rename <- grep("_weighted$", names(final_table), value = TRUE)
for(col in cols_to_rename) {
  num <- sub("_weighted$", "", col)
  if(num %in% names(rename_map)) {
    names(final_table)[names(final_table) == col] <- paste0(rename_map[num], "_weighted")
  }
}

# Clean structural parameters and export
final_table <- final_table %>% select(-any_of(c("NA", "ID", "Segment_ID_Key")))

cat("Writing final modeling table to destination...\n")
st_write(final_table, output_path, delete_dsn = TRUE, quiet = TRUE)
cat("Environmental Context pipeline execution complete.\n")