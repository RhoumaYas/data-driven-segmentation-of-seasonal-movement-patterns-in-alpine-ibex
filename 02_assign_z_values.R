#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(dplyr)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3) {
  stop("Usage: Rscript 02_assign_z_values.R <input_gpkg> <dem_path_or_none> <output_gpkg>")
}

input_gpkg <- args[1]
dem_path   <- args[2]
output_gpkg <- args[3]

# ---- Load points ----
cat("Loading GPKG...\n")
gdf <- st_read(input_gpkg, quiet = TRUE)

# ---- Convert to terra vector ----
v <- vect(gdf)

# ---- DEM extraction (optional) ----
if (tolower(dem_path) != "none") {
    cat("Loading DEM...\n")
    dem <- rast(dem_path)

    cat("Extracting elevation values...\n")

    n <- nrow(gdf)
    chunk_size <- ceiling(n * 0.05)   # dynamic chunk size = 5%
    z_vals <- numeric(n)

    pb <- txtProgressBar(min = 0, max = n, style = 3)

    for (i in seq(1, n, by = chunk_size)) {
        idx <- i:min(i + chunk_size - 1, n)
        z_vals[idx] <- terra::extract(dem, v[idx, ])[,2]
        setTxtProgressBar(pb, max(idx))
    }

    close(pb)
    cat("\nExtraction complete.\n")

    # Replace NA or -9999 with Height_m
    z_final <- ifelse(is.na(z_vals) | z_vals == -9999, gdf$Height_m, z_vals)

} 
else {
  cat("No DEM provided. Using Height_m as z.\n")
  z_final <- gdf$Height_m
}


# ---- Add z column ----
gdf$z <- z_final

# ---- Write output ----
cat("Writing output to", output_gpkg, "...\n")
st_write(gdf, output_gpkg, delete_dsn = TRUE, quiet = TRUE)

cat("Done.")
