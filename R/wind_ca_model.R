# Roozbeh Valavi
# 2022-05-24
#
# Additions by Alex Slavenko
# 2022-10-26
#
# simulate wind dispersal with cellular automata
wind_sim <- function(data_path = "wind-data",
                     coords = list(), # list of starting coordinates, each a vector of c(longitude, latitude)
                     # long = 145,
                     # lat = -37.8,
                     nforecast = 24, # number of forecast hours
                     nsim = 10, # number of simulations to calculate frequency
                     fdate = "20220524", # the forecast data
                     fhour = "18", # the forecast hour
                     atm_level = "850mb",
                     cellsize = 25000,
                     full = F, # if TRUE, generate a dataframe of endpoints per time step
                     parallel = F, # if TRUE run in parallel
                     ncores = F, # if FALSE (default) use max number of cores - 1. Else set to number of cores to use
                     backwards = F, # if FALSE (default) run forwards simulation from starting point. Else backwards from end point
                     updateProgress = NULL){

  require(tidyverse)
  require(terra)

  # identify the correct forecast cycle

  # define the interval
  interval <- c("00", "06", "12", "18")

  if(backwards){
    # update date and time based on length of hindcast
    fdate = as.character(format(as.POSIXct(lubridate::ymd_h(paste(fdate, fhour)) - lubridate::hours(as.numeric(nforecast)),format='%m/%d/%Y %H:%M:%S'),format='%Y%m%d'))

    fhour = as.character(lubridate::hour(lubridate::hours(as.numeric(fhour)) - lubridate::hours(nforecast)) %% 24)
  }

  # find closest interval
  diffs <- as.numeric(fhour) - as.numeric(interval)

  diffs[which(diffs < 0)] <- NA

  # calculate the index of the closest interval
  index <- which.min(diffs)

  # calculate the difference
  difference <- as.numeric(fhour) - as.numeric(interval[index])

  # get the corresponding interval
  fhour <- interval[index]

  # load data
  pathway <- file.path(data_path, fdate, fhour)

  files <- gfs_names(path = pathway)

  if(nforecast > 48){
    nfdate = as.character(format(lubridate::ymd(fdate) + 2, "%Y%m%d"))
    npathway = file.path(data_path, nfdate, fhour)

    nfiles <- gfs_names(path = npathway)
    nfiles$forecast <- sprintf("f%03d" ,as.numeric(stringr::str_remove(nfiles$forecast, "f")) + 48)

    files <- bind_rows(files, nfiles)
  }

  if(parallel){
    require(doSNOW)
    require(foreach)

    cores = parallel::detectCores(logical = T)
    if(!is.numeric(ncores))
      ncores <- cores[1]-1 else
        if(ncores > cores[1])
          stop("Number of threads must be equal to or less than available threads in system")

    ncores = min(ncores, length(coords))
    print(paste("Running in parallel using", ncores, "threads"))

    cl <- makeCluster(ncores)
    registerDoSNOW(cl)

    print("Simulating:")
    pb <- txtProgressBar(min=0, max=length(coords) * nsim , style = 3, char="=")
    progress <- function(n) {
      setTxtProgressBar(pb, n)

      # If we were passed a progress update function, call it
      if (is.function(updateProgress)) {
        updateProgress(value = n)
      }
    }
    opts <- list(progress = progress)

    npoint <- foreach(point = 1:length(coords), .combine = "c") %:%
      foreach(rep = seq_len(nsim), .packages = c("tidyverse", "terra"), .export = c("read_u", "read_v", "wind_speed", "wind_direction", "next_cell"), .options.snow = opts, .combine = "c") %dopar% {

        r <- terra::rast(file.path(data_path, fdate, fhour, files$file[1]))

        # extract coordinates
        long = coords[[point]][1]
        lat = coords[[point]][2]

        # empty raster for simulations
        fct_raster <- r
        fct_raster[] <- 0
        names(fct_raster) <- "wind_forecast"

        xlen <- terra::ncol(r)
        ylen <- terra::nrow(r)

        # weights for the output
        wt <- c(1, 1, 1, 1, 3, 1, 1, 1, 1)

        points_full <- tibble(x = numeric(), y = numeric(), nsim = numeric(), nforecast = numeric())

        points <- data.frame(x = colFromX(r, long),
                             y = rowFromY(r, lat),
                             nforecast = 0)

        n <- 1

        forecast_hours <- seq_len(nforecast)
        if(backwards) forecast_hours <- rev(forecast_hours)

        for(f in forecast_hours){

          if(f > 48){
            read_date = nfdate
            read_pathway = npathway
            difference = 0
          } else {
            read_date = fdate
            read_pathway = pathway
          }

          x <- points[n, 1]
          y <- points[n, 2]

          forecasts <- unique(files$forecast)

          u <- read_u(path = read_pathway, files_list = files, date = read_date, fcast = forecasts[f + difference], lev = atm_level)
          v <- read_v(path = read_pathway, files_list = files, date = read_date, fcast = forecasts[f + difference], lev = atm_level)

          # calculate wind speed and direction
          speed <- wind_speed(u = u, v = v)
          direction <- wind_direction(u = u, v = v)

          if(backwards)
            direction <- (direction + 180) %% 360

          speed_ctr <- speed[y, x][1,1]

          ## calculate the number of steps based on wind speed and cell size
          # if we choose at least 1 step each time there could be too many steps overall
          # when the speed is low that results in overshooting, i.e. trajectoies longer than reality
          # this could be happening because of course raster resolution
          # so I made it random, to have some movement with low wind speed, but not always
          # better solution is possible; saving distance when lower than one cell?
          steps <- max(sample(0:1, 1), ceiling(speed_ctr * 3600 / cellsize))
          # steps <- max(1, ceiling(speed_ctr * 3600 / cellsize))

          if(steps < 1) next

          for(e in seq_len(steps)){
            nbr_dir <- c()
            nbr_spd <- c()
            for(i in c(-1, 0, 1)){
              for(j in c(-1, 0, 1)){
                if(x + i < xlen && y + j < ylen){
                  nbr_dir <- c(nbr_dir, direction[y+j, x+i][1,1])
                  nbr_spd <- c(nbr_spd, speed[y+j, x+i][1,1])
                }
              }
            }
            # multiply the weight with the speeds
            probs <- wt * nbr_spd
            # add some randomness to the direction
            selected_dir <- sample(x = nbr_dir, size = 1, prob = probs)
            selected_dir <- selected_dir + runif(1, -30, 30)
            # keep the random direction within 0-360
            selected_dir <- selected_dir %% 360
            # calculate the next point
            newpoint <- next_cell(selected_dir, x, y)
            fct_raster[newpoint[2], newpoint[1]] <- fct_raster[newpoint[2], newpoint[1]][1,1] + 1

            n <- n + 1
            points[n, "x"] <- newpoint[1]
            points[n, "y"] <- newpoint[2]
            points[n, "nforecast"] <- f
          }
        }

        if (full) {
          points_full <- bind_rows(points_full,
                                   as_tibble(xyFromCell(r,
                                                        cellFromRowCol(r,
                                                                       points[,"y"],
                                                                       points[,"x"]))) %>%
                                     mutate(nsim = rep,
                                            nforecast = points$nforecast,
                                            x_start = long,
                                            y_start = lat))
          list(raster::raster(fct_raster), points_full)
        } else
          raster::raster(fct_raster)
      }
    close(pb)
    stopCluster(cl)
  } else {
    r <- terra::rast(file.path(pathway, files$file[1]))

    npoint <- list()

    print("Simulating:")
    progress_bar = txtProgressBar(min=0, max=length(coords) * nsim * nforecast, style = 3, char="=")

    for(point in 1:length(coords)){
      # extract coordinates
      long = coords[[point]][1]
      lat = coords[[point]][2]

      # empty raster for simulations
      fct_raster <- r
      fct_raster[] <- 0
      names(fct_raster) <- "wind_forecast"

      xlen <- terra::ncol(r)
      ylen <- terra::nrow(r)

      # weights for the output
      wt <- c(1, 1, 1, 1, 3, 1, 1, 1, 1)

      points_full <- tibble(x = numeric(), y = numeric(), nsim = numeric(), nforecast = numeric())

      for(rep in seq_len(nsim)){

        points <- data.frame(x = colFromX(r, long),
                             y = rowFromY(r, lat),
                             nforecast = 0)

        n <- 1

        forecast_hours <- seq_len(nforecast)
        if(backwards) forecast_hours <- rev(forecast_hours)

        for(f in forecast_hours){

          if(f > 48){
            read_date = nfdate
            read_pathway = npathway
            difference = 0
          } else {
            read_date = fdate
            read_pathway = pathway
          }

          x <- points[n, 1]
          y <- points[n, 2]

          forecasts <- unique(files$forecast)

          u <- read_u(path = read_pathway, files_list = files, date = read_date, fcast = forecasts[f + difference], lev = atm_level)
          v <- read_v(path = read_pathway, files_list = files, date = read_date, fcast = forecasts[f + difference], lev = atm_level)

          # calculate wind speed and direction
          speed <- wind_speed(u = u, v = v)
          direction <- wind_direction(u = u, v = v)

          if(backwards)
            direction <- (direction + 180) %% 360

          speed_ctr <- speed[y, x][1,1]

          ## calculate the number of steps based on wind speed and cell size
          # if we choose at least 1 step each time there could be too many steps overall
          # when the speed is low that results in overshooting, i.e. trajectoies longer than reality
          # this could be happening because of course raster resolution
          # so I made it random, to have some movement with low wind speed, but not always
          # better solution is possible; saving distance when lower than one cell?
          steps <- max(sample(0:1, 1), ceiling(speed_ctr * 3600 / cellsize))
          # steps <- max(1, ceiling(speed_ctr * 3600 / cellsize))

          if(steps < 1) next

          for(e in seq_len(steps)){
            nbr_dir <- c()
            nbr_spd <- c()
            for(i in c(-1, 0, 1)){
              for(j in c(-1, 0, 1)){
                if(x + i < xlen && y + j < ylen){
                  nbr_dir <- c(nbr_dir, direction[y+j, x+i][1,1])
                  nbr_spd <- c(nbr_spd, speed[y+j, x+i][1,1])
                }
              }
            }
            # multiply the weight with the speeds
            probs <- wt * nbr_spd
            # add some randomness to the direction
            selected_dir <- sample(x = nbr_dir, size = 1, prob = probs)
            selected_dir <- selected_dir + runif(1, -30, 30)
            # keep the random direction within 0-360
            selected_dir <- selected_dir %% 360
            # calculate the next point
            newpoint <- next_cell(selected_dir, x, y)
            fct_raster[newpoint[2], newpoint[1]] <- fct_raster[newpoint[2], newpoint[1]][1,1] + 1

            n <- n + 1
            points[n, "x"] <- newpoint[1]
            points[n, "y"] <- newpoint[2]
            points[n, "nforecast"] <- f
          }

          setTxtProgressBar(progress_bar,
                            value = (point - 1) * nsim * nforecast +
                              (rep - 1) * nforecast +
                              which(forecast_hours == f))

          # If we were passed a progress update function, call it
          if (is.function(updateProgress)) {
            updateProgress(value = (point - 1) * nsim * nforecast +
                             (rep - 1) * nforecast +
                             which(forecast_hours == f))
          }
        }

        if(full) {
          points_full <- bind_rows(points_full,
                                   as_tibble(xyFromCell(r,
                                                        cellFromRowCol(r,
                                                                       points[,"y"],
                                                                       points[,"x"]))) %>%
                                     mutate(nsim = rep,
                                            nforecast = points$nforecast,
                                            x_start = long,
                                            y_start = lat))
          npoint[[point]] <- list(raster::raster(fct_raster), points_full)

        } else
          npoint[[point]] <- raster::raster(fct_raster)
      }
    }
  }

  if(full) {
    fct_raster <- raster::stack(lapply(npoint, "[[", 1))
    fct_raster <- raster::calc(fct_raster, sum)
    fct_raster[fct_raster == 0] <- NA
    points_full <- lapply(npoint, "[[", 2)
    return(list(rast(fct_raster), bind_rows(points_full)))
  } else {
    if (length(npoint) > 1) {
      fct_raster <- raster::stack(npoint)
      fct_raster <- raster::calc(fct_raster, sum)
    } else
      fct_raster <- raster::raster(fct_raster)

    fct_raster[fct_raster == 0] <- NA
    return(terra::rast(fct_raster))
  }
}


# simulate wind dispersal with cellular automata using historical data (6 hour increments)
wind_sim_hist <- function(data_u = NULL,
                          data_v = NULL,
                          coords = list(), # list of starting coordinates, each a vector of c(longitude, latitude)
                          nforecast = 24, # number of forward forecast hours
                          nsim = 10, # number of simulations to calculate frequency
                          fdate = "20220524", # the forecast data
                          fhour = "18", # the forecast hour
                          cellsize = 25000,
                          full = F, # if TRUE, generate a dataframe of endpoints per time step
                          backwards = F, # if FALSE (default) run forwards simulation from starting point. Else backwards from end point
                          parallel = F, # if TRUE run in parallel
                          ncores = F){ # if FALSE (default) use max number of cores - 1. Else set to number of cores to use

  require(tidyverse)
  require(terra)

  r <- data_u[[1]]

  # define the interval
  interval <- c("00", "06", "12", "18")

  if(backwards){
    # update date and time based on length of hindcast
    fdate = as.character(format(as.POSIXct(lubridate::ymd_h(paste(fdate, fhour)) - lubridate::hours(as.numeric(nforecast)),format='%m/%d/%Y %H:%M:%S'),format='%Y%m%d'))

    fhour = as.character(lubridate::hour(lubridate::hours(as.numeric(fhour)) - lubridate::hours(nforecast)) %% 24)
  }

  # find closest interval
  diffs <- as.numeric(fhour) - as.numeric(interval)

  diffs[which(diffs < 0)] <- NA

  # calculate the index of the closest interval
  index <- which.min(diffs)

  # calculate the difference
  difference <- as.numeric(fhour) - as.numeric(interval[index])

  # get the corresponding interval
  fhour <- interval[index]

  if(parallel){
    require(doSNOW)
    require(foreach)

    dir.create("tmp")
    writeRaster(r, "tmp/r.tif")
    writeRaster(data_u, "tmp/data_u.tif")
    writeRaster(data_v, "tmp/data_v.tif")

    cores = parallel::detectCores(logical = T)
    if(!is.numeric(ncores))
      ncores <- cores[1]-1 else
        if(ncores > cores[1])
          stop("Number of threads must be equal to or less than available threads in system")

    ncores = min(ncores, length(coords))
    print(paste("Running in parallel using", ncores, "threads"))

    cl <- makeCluster(ncores)
    registerDoSNOW(cl)

    print("Simulating:")
    pb <- txtProgressBar(min=0, max=length(coords), style = 3, char="=")
    progress <- function(n) setTxtProgressBar(pb, n)
    opts <- list(progress = progress)

    npoint <- foreach(point = 1:length(coords), .packages = c("tidyverse", "terra"), .export = c("wind_speed", "wind_direction", "next_cell"), .options.snow = opts) %dopar% {

      r <- rast("tmp/r.tif")
      data_u <- rast("tmp/data_u.tif")
      data_v <- rast("tmp/data_v.tif")

      # extract coordinates
      long = coords[[point]][1]
      lat = coords[[point]][2]

      # empty raster for simulations
      fct_raster <- r
      fct_raster[] <- 0
      names(fct_raster) <- "wind_forecast"

      xlen <- terra::ncol(r)
      ylen <- terra::nrow(r)

      # weights for the output
      wt <- c(1, 1, 1, 1, 3, 1, 1, 1, 1)

      points_full <- tibble(x = numeric(), y = numeric(), nsim = numeric(), nforecast = numeric())

      for(rep in seq_len(nsim)){

        points <- data.frame(x = colFromX(r, long),
                             y = rowFromY(r, lat),
                             nforecast = 0)

        n <- 1

        for(f in seq_len(nforecast)){

          f_new <- f + f_offset

          x <- points[n, 1]
          y <- points[n, 2]

          start_layer <- which(names(data_u) == paste0(fdate, fhour))

          u <- data_u[[start_layer + floor(f_new/6)]]
          v <- data_v[[start_layer + floor(f_new/6)]]

          # calculate wind speed and direction
          speed <- wind_speed(u = u, v = v)
          direction <- wind_direction(u = u, v = v)

          speed_ctr <- speed[y, x][1,1]

          ## calculate the number of steps based on wind speed and cell size
          # if we choose at least 1 step each time there could be too many steps overall
          # when the speed is low that results in overshooting, i.e. trajectoies longer than reality
          # this could be happening because of course raster resolution
          # so I made it random, to have some movement with low wind speed, but not always
          # better solution is possible; saving distance when lower than one cell?
          steps <- max(sample(0:1, 1), ceiling(speed_ctr * 3600 / cellsize))
          # steps <- max(1, ceiling(speed_ctr * 3600 / cellsize))

          if(steps < 1) next

          for(e in seq_len(steps)){
            nbr_dir <- c()
            nbr_spd <- c()
            for(i in c(-1, 0, 1)){
              for(j in c(-1, 0, 1)){
                if(x + i < xlen && y + j < ylen){
                  nbr_dir <- c(nbr_dir, direction[y+j, x+i][1,1])
                  nbr_spd <- c(nbr_spd, speed[y+j, x+i][1,1])
                }
              }
            }
            # multiply the weight with the speeds
            probs <- wt * nbr_spd
            # add some randomness to the direction
            selected_dir <- sample(x = nbr_dir, size = 1, prob = probs)
            selected_dir <- selected_dir + runif(1, -30, 30)
            # keep the random direction within 0-360
            selected_dir <- selected_dir %% 360
            # calculate the next point
            newpoint <- next_cell(selected_dir, x, y)
            fct_raster[newpoint[2], newpoint[1]] <- fct_raster[newpoint[2], newpoint[1]][1,1] + 1

            n <- n + 1
            points[n, "x"] <- newpoint[1]
            points[n, "y"] <- newpoint[2]
            points[n, "nforecast"] <- f
          }
        }

        if (full)
          points_full <- bind_rows(points_full,
                                   as_tibble(xyFromCell(r,
                                                        cellFromRowCol(r,
                                                                       points[,"y"],
                                                                       points[,"x"]))) %>%
                                     mutate(nsim = rep,
                                            nforecast = points$nforecast,
                                            x_start = long,
                                            y_start = lat))
      }

      if(full)
        list(raster::raster(fct_raster), points_full) else
          raster::raster(fct_raster)
    }
    close(pb)
    stopCluster(cl)

    unlink("tmp")
  } else {

    npoint <- list()

    print("Simulating:")
    progress_bar = txtProgressBar(min=0, max=length(coords), style = 3, char="=")

    for(point in 1:length(coords)){
      # extract coordinates
      long = coords[[point]][1]
      lat = coords[[point]][2]

      # empty raster for simulations
      fct_raster <- r
      fct_raster[] <- 0
      names(fct_raster) <- "wind_forecast"

      xlen <- terra::ncol(r)
      ylen <- terra::nrow(r)

      # weights for the output
      wt <- c(1, 1, 1, 1, 3, 1, 1, 1, 1)

      points_full <- tibble(x = numeric(), y = numeric(), nsim = numeric(), nforecast = numeric())

      for(rep in seq_len(nsim)){

        points <- data.frame(x = colFromX(r, long),
                             y = rowFromY(r, lat),
                             nforecast = 0)

        n <- 1

        forecast_hours <- seq_len(nforecast)
        if(backwards) forecast_hours <- rev(forecast_hours)

        for(f in forecast_hours){

          f_new <- f + difference

          x <- points[n, 1]
          y <- points[n, 2]

          start_layer <- which(names(data_u) == paste0(fdate, interval[index]))

          u <- data_u[[start_layer + floor(f_new/6)]]
          v <- data_v[[start_layer + floor(f_new/6)]]

          # calculate wind speed and direction
          speed <- wind_speed(u = u, v = v)
          direction <- wind_direction(u = u, v = v)

          if(backwards)
            direction <- (direction + 180) %% 360

          speed_ctr <- speed[y, x][1,1]

          ## calculate the number of steps based on wind speed and cell size
          # if we choose at least 1 step each time there could be too many steps overall
          # when the speed is low that results in overshooting, i.e. trajectoies longer than reality
          # this could be happening because of course raster resolution
          # so I made it random, to have some movement with low wind speed, but not always
          # better solution is possible; saving distance when lower than one cell?
          steps <- max(sample(0:1, 1), ceiling(speed_ctr * 3600 / cellsize))
          # steps <- max(1, ceiling(speed_ctr * 3600 / cellsize))

          if(steps < 1) next

          for(e in seq_len(steps)){
            nbr_dir <- c()
            nbr_spd <- c()
            for(i in c(-1, 0, 1)){
              for(j in c(-1, 0, 1)){
                if(x + i < xlen && y + j < ylen){
                  nbr_dir <- c(nbr_dir, direction[y+j, x+i][1,1])
                  nbr_spd <- c(nbr_spd, speed[y+j, x+i][1,1])
                }
              }
            }
            # multiply the weight with the speeds
            probs <- wt * nbr_spd
            # add some randomness to the direction
            selected_dir <- sample(x = nbr_dir, size = 1, prob = probs)
            selected_dir <- selected_dir + runif(1, -30, 30)
            # keep the random direction within 0-360
            selected_dir <- selected_dir %% 360
            # calculate the next point
            newpoint <- next_cell(selected_dir, x, y)
            fct_raster[newpoint[2], newpoint[1]] <- fct_raster[newpoint[2], newpoint[1]][1,1] + 1

            n <- n + 1
            points[n, "x"] <- newpoint[1]
            points[n, "y"] <- newpoint[2]
            points[n, "nforecast"] <- f
          }
        }

        if(full) {
          points_full <- bind_rows(points_full,
                                   as_tibble(xyFromCell(r,
                                                        cellFromRowCol(r,
                                                                       points[,"y"],
                                                                       points[,"x"]))) %>%
                                     mutate(nsim = rep,
                                            nforecast = points$nforecast,
                                            x_start = long,
                                            y_start = lat))
          npoint[[point]] <- list(raster::raster(fct_raster), points_full)

        } else
          npoint[[point]] <- raster::raster(fct_raster)

        setTxtProgressBar(progress_bar, value = point)
      }
    }
  }

  if(full) {
    if (length(npoint) > 1) {
      fct_raster <- raster::stack(lapply(npoint, "[[", 1))
      fct_raster <- raster::calc(fct_raster, sum)
    } else
      fct_raster <- raster::raster(fct_raster)

    fct_raster[fct_raster == 0] <- NA

    points_full <- lapply(npoint, "[[", 2)
    return(list(terra::rast(fct_raster), bind_rows(points_full)))
  } else {
    if (length(npoint) > 1) {
      fct_raster <- raster::stack(npoint)
      fct_raster <- raster::calc(fct_raster, sum)
    } else
      fct_raster <- raster::raster(fct_raster)

    fct_raster[fct_raster == 0] <- NA
    return(terra::rast(fct_raster))
  }
}
