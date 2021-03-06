#' Function to parse a EuroMOMO specification file.
#'
#' The function sets R-EuroMOMO algorithm parameters based on a cascading series of TXT file consisting
#' of <Lefthandside> = <Righthandside> operators.
#'
#' Operation: Each <LHS> = <RHS> is stored in a list. There are two special
#' LHS's: except and group, which are used to specify exception periods and group
#' information. First a global defaults.txt file is ran and then possibly local
#' defaults are run. Parameters which need to be here: see ImportantVarNames in checkOptions.\cr\cr
#' Syntax for specifying groups: \code{<group>.<groupName>.<attributeName> = <attributeValue}. \cr
#' Syntax for specifying except periods: \code{except = <Start ISO-week>:<End ISO-week>}. \cr \cr
#' There are five pre-defined age groups: momodefault<1-5>.
#'
#' @note The parser is handwritten based on regular expressions, which is prone to error.
#' Future versions could be, e.g., XML based.
#' @param fileName of the parameter configuration file
#' @param debug if true print extensive information
#' @export

parseDefaultsFile <- function(fileName, debug=FALSE) {
  #Read in file with default parameter configrations
  defaultFile<-NULL
  candidates<-c(system.file("extdata", "defaults.txt", package="euromomo"),
                file.path(getwd(), "inst","extdata", "defaults.txt"))
  if (file.exists(candidates[1])) {
    cat("Using package file.\n")
    defaultFile <- candidates[1]
  }
  if(is.null(defaultFile) & file.exists(candidates[2])) {
    cat("Using: ",candidates[2] ,"\n")
    defaultFile <- candidates[2]
  }
  if(!file.exists(fileName)) {
    warning("The specified file \"", fileName, "\" does not exist. I'm ignoring it!")
    fileName<-NULL
  }
  #Make the list of files.
  files <- c(defaultFile, fileName)

  if(length(files)==0) stop("No parameter configuration file found.")
  if(debug) cat("Using these files: ",paste(files,collapse=", "),"\n")

  #Read all files
  dats <- unlist(sapply(files,readLines))

  #Strip lines starting with comment symbol and remove empty lines.
  dats <- dats[!grepl("^#",dats)]
  dats <- dats[nchar(dats)>0]
  if(debug) print(head(dats))

  # Split each line on the first equal sign
  splits <- regmatches(dats, regexpr("=",dats), invert=TRUE)

  # Initialize option object containing except and groups slot.
  out <- list(except=list(), groups=list())

  # Loop over all remaining lines.
  for(i in 1:length(splits)) {
    #Identifiers starting with 'group.' or 'except' need to be handled specially.
    if(!grepl("^\\w*(group\\.|except\\w*$)", splits[[i]][1])){
      label <- splits[[i]][1]
      value <- splits[[i]][2]
      out[[label]] <- value
    } else {
      if (grepl("^\\w*group\\.", splits[[i]][1])){ #group definition?
        #Identify group name and group attribute & add to list
        nameAndAttr <- strsplit(splits[[i]],"[.]")[[1]][2:3]
        out$groups[[nameAndAttr[1]]][[nameAndAttr[2]]] <- splits[[i]][2]
      } else { #except definition
        #Start & End of date range & add to list
        startEnd <- c(strsplit(splits[[i]][2], ":"))
        out$except <- rbind(out$except, startEnd[[1]])
      }
    }
  }

  # Check that the StartDelayEst variable is valid
  if (grepl("^[0-9]{4}-W[0-9]{2}$",out$StartDelayEst)) {
    tryCatch(ISOweek2date(paste0(out$StartDelayEst,"-1")),error=function(e) {
      stop("StartDelayEst=",out$StartDelayEst," is not a valid ISO week specification (YYYY-WXX):\n",e)
    })
  } else {
    stop("StartDelayEst=",out$StartDelayEst," is not a valid ISO week specification (YYYY-WXX).")
  }

  # Check that DayOfAggregation is given, otherwise replace with today's date
  if(is.null(out$DayOfAggregation)){
    out$DayOfAggregation <- Sys.Date()
    warning(paste("DayOfAggregation was not given. SystemDate (", Sys.Date(), ") was used instead.\n", sep=""))
  }

  options(euromomo=out)
  invisible(out)
}

#' Checking of the euromomo options.
#'
#' Function to check, if the currently list stored in options("euromomo")
#' is semantically valid.
#'
#' At the moment, this check consists of:
#' \enumerate{
#' \item Check for all entries in 'except' that dStart <= dEnd
#' \item Each group has a 'definition' and a 'label' attribute.
#' \item That all Boolean Attributes (e.g. 'trend' and 'seasonality') are really Booleans.
#' At the first error the function stops.
#' }
#' @note Only one error at the time is found.
#' @return TRUE, if function finds no errors. Otherwise a "stop" halts function execution.
#' @export
checkOptions <- function() {
  #Extract from global options
  opts <- getOption("euromomo")

  #Check that all important variables are there
  importantVarNames <- c("Country",
                         "Counties",
                         "Institution",
                         "WorkDirectory",
                         "InputFile",
                         "HolidayFile",
                         "BaselineSeasons",
                         "StartDelayEst")

  idxMissing <- which(!(importantVarNames %in% names(opts)))
  if (length(idxMissing)>0) {
    stop("The following variable names are missing: ",importantVarNames[idxMissing],"\n.")
  }

  # Check if DayOfAggregation is valid.
  if(as.Date(opts$DayOfAggregation)>Sys.Date()){
    stop("Invalid DayOfAggregation given.\n")
  }

  #Check that if there are ISO weeks of except that these are valid.
  if (length(opts[["except"]])>0) {
    dStart <- ISOweek::ISOweek2date(paste(opts$except[,1],"-1",sep=""))
    dEnd <- ISOweek::ISOweek2date(paste(opts$except[,2],"-1",sep=""))
    if (any(dStart > dEnd)) {
      idx <- which(dStart > dEnd)
      stop(paste("dStart > dEnd for entries:", paste(opts$except[idx,],collapse=" : ")))
    }
  }

  #Check that each group has at least the two necessary attributes
  groups <- opts[["groups"]]

  for (i in 1:length(groups)) {
    #Check that the important attributes are there.
    importantAttr <- c("definition","label", "back")
    attrThere <- importantAttr %in% names(groups[[i]])
    if (!all(attrThere)) {
      stop(paste("Group \"",names(groups)[i],"\" is missing the attribute \"",importantAttr[!attrThere],"\"",sep=""))
    }


    #Convert booleans
    booleanAttributes <- c("seasonality","trend")
    for (attr in booleanAttributes) {
      if (attr %in% names(groups[[i]])) {
        if (is.na(as.logical(groups[[i]][[attr]]))) {
          stop(paste("Attribute \"",attr,"\" of group \"",names(groups)[i],"\" is not logical (TRUE/FALSE).",sep=""))
        }
      }
    }
  }

  #Check optional parameters of type from:to (where both from and to are integers)
  fromToVarNames <- c("spring","autumn")
  for (i in 1:length(fromToVarNames)) {
    if (fromToVarNames[i] %in% names(opts)) {
      #Check that in format from:to
      fromto <- strsplit( opts[[fromToVarNames[i]]], ":")[[1]]
      if (any(is.na(as.numeric(fromto)))) {
        stop("Definition of \"",fromToVarNames[i],"\" is not in the format from:to.\n")
      }
    }
  }

  #If we get here there were no errors.
  invisible(TRUE)
}

doIt <- function() {
  source("defaults.R")
  #Assume getwd is equal to $WHATEVER/euromomo/
  parseDefaultsFile("defaults-example.txt")
  checkOptions()
  #Extract stored list
  opts <- getOption("euromomo")
  opts
  momoWithGroups <- makeGroups(momo)

}
