#-------------------------------------------------------------------------------
#
# Script to extract and process VMS and logbook data for ICES VMS data call
#
# By: Niels Hintzen, Katell Hamon, Marcel Machiels
# Code by: Niels Hintzen
# Contact: niels.hintzen@wur.nl
#
# Date: 25-Jan-2017
#
# Client: ICES
#-------------------------------------------------------------------------------

#--------------------READ ME----------------------------------------------------
# The following script is a proposed workflow example to processes the ICES
# VMS datacall request. It is not an exact template to be applied to data from
# every member state and needs to be adjusted according to the data availability
# and needs of every member state.
#-------------------------------------------------------------------------------


#- Clear workspace
rm(list=ls())

library(vmstools) #- download from www.vmstools.org
library(Matrix)   #- available on CRAN
library(ggplot2)  #- available on CRAN

#- Settings paths
codePath  <- "D:/VMSdatacall/R/"          #Location where you store R scripts
dataPath  <- "D:/VMSdatacall/Data/"       #Location where you store tacsat (VMS) and eflalo (logbook) data
outPath   <- "D:/VMSdatacall/Results/"    #Location where you want to store the results
polPath   <- "D:/VMSdatacall/Polygons/"   #Location where you store the HELCOM and OSPAR polygons

#- Setting specific thresholds
spThres       <- 20   #Maximum speed threshold in analyses in nm
intThres      <- 5    #Minimum difference in time interval in minutes to prevent pseudo duplicates
intvThres     <- 240  #Maximum difference in time interval in minutes to prevent intervals being too large to be realistic
lanThres      <- 1.5  #Maximum difference in log10-transformed sorted weights

#- Load OSPAR and HELCOM areas (download from http://geo.ices.dk/index.php)
helcom        <- readShapePoly(file.path(polPath,"helcom_subbasins"))
ospar         <- readShapePoly(file.path(polPath,"ospar_regions_without_coastline"))

#- Re-run all years or only update 2017
yearsToSubmit <- sort(2009:2017)

#- Set the gear names for which automatic fishing activity is wanted
#  It is important to fill out the gears you want to apply auto detection for
autoDetectionGears        <- c("TBB","OTB","OTT","SSC","SDN","DRB","PTB","HMD")

#- Decide if you want to visualy analyse speed-histograms to identify fishing activity
#  peaks or have prior knowledge and use the template provided around lines 380 below
visualInspection          <- FALSE

#- Specify how landings should be distributed over the VMS pings: By day, ICES rectangle, trip basis or otherwise
linkEflaloTacsat          <- c("day","ICESrectangle","trip")
# other options
# linkEflaloTacsat          <- c("day","ICESrectangle","trip")
# linkEflaloTacsat          <- c("ICESrectangle","trip")
# linkEflaloTacsat          <- c("day","trip")
# linkEflaloTacsat          <- c("trip")


#-------------------------------------------------------------------------------
#- 1) Load the data
#-------------------------------------------------------------------------------

  #-------------------------------------------------------------------------------
  #- 1a) load vmstools underlying data
  #-------------------------------------------------------------------------------
  data(euharbours); if(substr(R.Version()$os,1,3)== "lin") data(harbours)
  data(ICESareas)
  data(europa)

  #-------------------------------------------------------------------------------
  #- 1b) Looping through the data years
  #-------------------------------------------------------------------------------

for(year in yearsToSubmit){
  print(year)
  #-------------------------------------------------------------------------------
  #- 1c) load tacsat and eflalo data from file (they need to be in tacsat2 and
  #       eflalo2 format already
  #       (see https://github.com/nielshintzen/vmstools/releases/ -> downloads ->
  #                     Exchange_EFLALO2_v2-1.doc for an example
  #-------------------------------------------------------------------------------
  load(file.path(dataPath,paste("tacsat_",year,".RData",sep=""))); #- data is saved as tacsat_2009, tacsat_2010 etc
  load(file.path(dataPath,paste("eflalo_",year,".RData",sep=""))); #- data is saved as eflalo_2009, eflalo_2010 etc

  tacsat <- get(paste("tacsat_",year,sep="")) #- Data is loaded as tacsat_year, -> rename to tacsat
  eflalo <- get(paste("eflalo_",year,sep="")) #- Data is loaded as eflalo_year, -> rename to eflalo

  #- Make sure data is in right format
  tacsat            <- formatTacsat(tacsat)
  eflalo            <- formatEflalo(eflalo)
  
  #- Take only VMS pings in the ICES areas, Helcom and/or Ospar regions
  idxH              <- over(SpatialPoints(tacsat[,c("SI_LONG","SI_LATI")]),as(helcom,"SpatialPolygons"))
  idxO              <- over(SpatialPoints(tacsat[,c("SI_LONG","SI_LATI")]),as(ospar,"SpatialPolygons"))
  idxI              <- over(SpatialPoints(tacsat[,c("SI_LONG","SI_LATI")]),as(ICESareas,"SpatialPolygons"))
  tacsat            <- tacsat[which(idxH>0 | idxO>0 | idxI >0),]
  
  coordsEflalo      <- ICESrectangle2LonLat(na.omit(unique(eflalo$LE_RECT)))
  coordsEflalo$LE_RECT <- na.omit(unique(eflalo$LE_RECT))
  coordsEflalo      <- coordsEflalo[is.na(coordsEflalo[,1]) == F | is.na(coordsEflalo[,2]) == F,]
  cornerPoints      <- list()
  for(i in 1:nrow(coordsEflalo))
    cornerPoints[[i]] <- cbind(SI_LONG=coordsEflalo[i,"SI_LONG"]+c(0,0.5,1,1,0),
                               SI_LATI=coordsEflalo[i,"SI_LATI"]+c(0,0.25,0,0.5,0.5),
                               LE_RECT=coordsEflalo[i,"LE_RECT"])
  coordsEflalo      <- as.data.frame(do.call(rbind,cornerPoints),stringsAsFactors=FALSE)
  coordsEflalo$SI_LONG <- an(coordsEflalo$SI_LONG)
  coordsEflalo$SI_LATI <- an(coordsEflalo$SI_LATI)
  idxH              <- over(SpatialPoints(coordsEflalo[,c("SI_LONG","SI_LATI")]),as(helcom,"SpatialPolygons"))
  idxO              <- over(SpatialPoints(coordsEflalo[,c("SI_LONG","SI_LATI")]),as(ospar,"SpatialPolygons"))
  idxI              <- over(SpatialPoints(coordsEflalo[,c("SI_LONG","SI_LATI")]),as(ICESareas,"SpatialPolygons"))
  eflalo            <- subset(eflalo,LE_RECT %in% unique(coordsEflalo[which(idxH>0 | idxO > 0 | idxI > 0),"LE_RECT"]))
  
#-------------------------------------------------------------------------------
#- 2) Clean the tacsat data
#-------------------------------------------------------------------------------

  #-------------------------------------------------------------------------------
  #- Keep track of removed points
  #-------------------------------------------------------------------------------
  remrecsTacsat     <- matrix(NA,nrow=6,ncol=2,dimnames=list(c("total","duplicates","notPossible","pseudoDuplicates","harbour","land"),c("rows","percentage")))
  remrecsTacsat["total",] <- c(nrow(tacsat),"100%")

  #-------------------------------------------------------------------------------
  #- Remove duplicate records
  #-------------------------------------------------------------------------------
  tacsat$SI_DATIM <- as.POSIXct(paste(tacsat$SI_DATE,  tacsat$SI_TIME,   sep=" "), tz="GMT", format="%d/%m/%Y  %H:%M")
  uniqueTacsat    <- paste(tacsat$VE_REF,tacsat$SI_LATI,tacsat$SI_LONG,tacsat$SI_DATIM)
  tacsat          <- tacsat[!duplicated(uniqueTacsat),]
  remrecsTacsat["duplicates",] <- c(nrow(tacsat),100+round((nrow(tacsat) - an(remrecsTacsat["total",1]))/an(remrecsTacsat["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove points that cannot be possible
  #-------------------------------------------------------------------------------
  idx             <- which(abs(tacsat$SI_LATI) > 90 | abs(tacsat$SI_LONG) > 180)
  idx             <- unique(c(idx,which(tacsat$SI_HE < 0 | tacsat$SI_HE > 360)))
  idx             <- unique(c(idx,which(tacsat$SI_SP > spThres)))
  if(length(idx)>0) tacsat          <- tacsat[-idx,]
  remrecsTacsat["notPossible",] <- c(nrow(tacsat),100+round((nrow(tacsat) - an(remrecsTacsat["total",1]))/an(remrecsTacsat["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove points which are pseudo duplicates as they have an interval rate < x minutes
  #-------------------------------------------------------------------------------
  tacsat          <- sortTacsat(tacsat)
  tacsatp         <- intervalTacsat(tacsat,level="vessel",fill.na=T)
  tacsat          <- tacsatp[which(tacsatp$INTV > intThres | is.na(tacsatp$INTV)==T),-grep("INTV",colnames(tacsatp))]
  remrecsTacsat["pseudoDuplicates",] <- c(nrow(tacsat),100+round((nrow(tacsat) - an(remrecsTacsat["total",1]))/an(remrecsTacsat["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove points in harbour
  #-------------------------------------------------------------------------------
  idx             <- pointInHarbour(tacsat$SI_LONG,tacsat$SI_LATI,harbours); pih <- tacsat[which(idx == 1),]
  save(pih,file=paste(outPath,"pointInHarbour",year,".RData",sep=""))
  tacsat          <- tacsat[which(idx == 0),]
  remrecsTacsat["harbour",] <- c(nrow(tacsat),100+round((nrow(tacsat) - an(remrecsTacsat["total",1]))/an(remrecsTacsat["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove points on land
  #-------------------------------------------------------------------------------
  pols            <- lonLat2SpatialPolygons(lst=lapply(as.list(sort(unique(europa$SID))),
                        function(x){data.frame(SI_LONG=subset(europa,SID==x)$X,SI_LATI=subset(europa,SID==x)$Y)}))
  idx             <- pointOnLand(tacsat,pols); pol <- tacsat[which(idx == 1),]
  save(pol,file=paste(outPath,"pointOnLand",year,".RData",sep=""))
  tacsat          <- tacsat[which(idx == 0),]
  remrecsTacsat["land",] <- c(nrow(tacsat),100+round((nrow(tacsat) - an(remrecsTacsat["total",1]))/an(remrecsTacsat["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Save the remrecsTacsat file
  #-------------------------------------------------------------------------------
  save(remrecsTacsat,file=file.path(outPath,paste("remrecsTacsat",year,".RData",sep="")))

  #-------------------------------------------------------------------------------
  #- Save the cleaned tacsat file
  #-------------------------------------------------------------------------------
  save(tacsat,file=file.path(outPath,paste("cleanTacsat",year,".RData",sep="")))

  print("Cleaning tacsat completed")
#-------------------------------------------------------------------------------
#- 3) Clean the eflalo data
#-------------------------------------------------------------------------------

  #-------------------------------------------------------------------------------
  #- Keep track of removed points
  #-------------------------------------------------------------------------------
  remrecsEflalo     <- matrix(NA,nrow=5,ncol=2,dimnames=list(c("total","duplicated","impossible time","before 1st Jan","departArrival"),c("rows","percentage")))
  remrecsEflalo["total",] <- c(nrow(eflalo),"100%")

  #-------------------------------------------------------------------------------
  #- Warn for outlying catch records
  #-------------------------------------------------------------------------------

  # Put eflalo in order of 'non kg/eur' columns, then kg columns, then eur columns
  idxkg           <- grep("LE_KG_",colnames(eflalo))
  idxeur          <- grep("LE_EURO_",colnames(eflalo))
  idxoth          <- which(!(1:ncol(eflalo)) %in% c(idxkg,idxeur))
  eflalo          <- eflalo[,c(idxoth,idxkg,idxeur)]

  #First get the species names in your eflalo dataset
  specs           <- substr(colnames(eflalo[grep("KG",colnames(eflalo))]),7,9)

  #Define per species what the maximum allowed catch is (larger than that value you expect it to be an error / outlier
  specBounds      <- lapply(as.list(specs),function(x){
                            idx   <- grep(x,colnames(eflalo))[grep("KG",colnames(eflalo)[grep(x,colnames(eflalo))])];
                            wgh   <- sort(unique(eflalo[which(eflalo[,idx]>0),idx]));
                            difw  <- diff(log10(wgh));
                            return(ifelse(any(difw > lanThres),wgh[rev(which(difw <= lanThres)+1)],ifelse(length(wgh)==0,0,max(wgh,na.rm=T))))})

  #Make a list of the species names and the cut-off points / error / outlier point
  specBounds      <- cbind(specs,unlist(specBounds));

  #Put these values to zero
  specBounds[which(is.na(specBounds[,2])==T),2] <- "0"

  #Get the index (column number) of each of the species
  idx             <- unlist(lapply(as.list(specs),function(x){
                            idx             <- grep(x,colnames(eflalo))[grep("KG",colnames(eflalo)[grep(x,colnames(eflalo))])];
                            return(idx)}))

  #If landing > cut-off turn it into an 'NA'
  warns           <- list()
  fixWarns        <- TRUE
  for(iSpec in idx){
    if(length(which(eflalo[,iSpec] > an(specBounds[(iSpec-idx[1]+1),2])))>0){
      warns[[iSpec]] <- which(eflalo[,iSpec] > an(specBounds[(iSpec-idx[1]+1),2]))
      if(fixWarns){
        eflalo[which(eflalo[,iSpec] > an(specBounds[(iSpec-idx[1]+1),2])),iSpec] <- NA
      }
    }
  }
  save(warns,file=file.path(outPath,paste("warningsSpecBound",year,".RData",sep="")))

  #Turn all other NA's in the eflalo dataset in KG and EURO columns to zero
  for(i in kgeur(colnames(eflalo))) eflalo[which(is.na(eflalo[,i]) == T),i] <- 0

  #-------------------------------------------------------------------------------
  #- Remove non-unique trip numbers
  #-------------------------------------------------------------------------------
  eflalo <- eflalo[!duplicated(paste(eflalo$LE_ID,eflalo$LE_CDAT,sep="-")),]
  remrecsEflalo["duplicated",] <- c(nrow(eflalo),100+round((nrow(eflalo) - an(remrecsEflalo["total",1]))/an(remrecsEflalo["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove impossible time stamp records
  #-------------------------------------------------------------------------------
  eflalo$FT_DDATIM <- as.POSIXct(paste(eflalo$FT_DDAT,eflalo$FT_DTIME, sep = " "), tz = "GMT", format = "%d/%m/%Y  %H:%M")
  eflalo$FT_LDATIM <- as.POSIXct(paste(eflalo$FT_LDAT,eflalo$FT_LTIME, sep = " "), tz = "GMT", format = "%d/%m/%Y  %H:%M")

  eflalo <- eflalo[!(is.na(eflalo$FT_DDATIM) |is.na(eflalo$FT_LDATIM)),]
  remrecsEflalo["impossible time",] <- c(nrow(eflalo),100+round((nrow(eflalo) - an(remrecsEflalo["total",1]))/an(remrecsEflalo["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove trip starting befor 1st Jan
  #-------------------------------------------------------------------------------
  eflalo <- eflalo[eflalo$FT_DDATIM>=strptime(paste(year,"-01-01 00:00:00",sep=''),"%Y-%m-%d %H:%M"),]
  remrecsEflalo["before 1st Jan",] <- c(nrow(eflalo),100+round((nrow(eflalo) - an(remrecsEflalo["total",1]))/an(remrecsEflalo["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Remove trip with overlap with another trip
  #-------------------------------------------------------------------------------

  eflalo           <- orderBy(~VE_COU+VE_REF+FT_DDATIM+FT_LDATIM,data=eflalo)
  overlaps         <- lapply(split(eflalo,as.factor(eflalo$VE_REF)),function(x){
                              x   <- x[!duplicated(paste(x$VE_REF,x$FT_REF)),]
                              idx <- apply(triu(matrix(an(outer(x$FT_DDATIM,x$FT_LDATIM,"-")),
                                               nrow=nrow(x),ncol=nrow(x))),2,function(y){which(y>0,arr.ind=T)})

                              rows      <- which(unlist(lapply(idx,length))>0)
                              return(rows)})
  eflalo$ID       <- 1:nrow(eflalo)
  for(iOver in 1:length(overlaps)){
    if(length(overlaps[[iOver]])>0) eflalo <- eflalo[which(eflalo$VE_REF == names(overlaps)[iOver]),][-overlaps[[iOver]],]
  }

  #-------------------------------------------------------------------------------
  #- Remove records with arrival date before departure date
  #-------------------------------------------------------------------------------
  eflalop           <- eflalo
  idx               <- which(eflalop$FT_LDATIM >= eflalop$FT_DDATIM)
  eflalo            <- eflalo[idx,]
  remrecsEflalo["departArrival",] <- c(nrow(eflalo),100+round((nrow(eflalo) - an(remrecsEflalo["total",1]))/an(remrecsEflalo["total",1])*100,2))

  #-------------------------------------------------------------------------------
  #- Save the remrecsEflalo file
  #-------------------------------------------------------------------------------
  save(remrecsEflalo,file=file.path(outPath,paste("remrecsEflalo",year,".RData",sep="")))

  #-------------------------------------------------------------------------------
  #- Save the cleaned eflalo file
  #-------------------------------------------------------------------------------
  save(eflalo,file=file.path(outPath,paste("cleanEflalo",year,".RData",sep="")))

  print("Cleaning eflalo completed")
#-------------------------------------------------------------------------------
#- 4) Merge the tacsat and eflalo data together
#-------------------------------------------------------------------------------

  #-------------------------------------------------------------------------------
  #- Merge eflalo and tacsat
  #-------------------------------------------------------------------------------
  tacsatp           <- mergeEflalo2Tacsat(eflalo,tacsat)

  #-------------------------------------------------------------------------------
  #- Assign gear and length to tacsat
  #-------------------------------------------------------------------------------
  tacsatp$LE_GEAR   <- eflalo$LE_GEAR[match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$LE_MSZ    <- eflalo$LE_MSZ[ match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$VE_LEN    <- eflalo$VE_LEN[ match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$VE_KW     <- eflalo$VE_KW[  match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$LE_RECT   <- eflalo$LE_RECT[ match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$LE_MET    <- eflalo$LE_MET[  match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$LE_WIDTH  <- eflalo$LE_WIDTH[match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$VE_FLT    <- eflalo$VE_FLT[  match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$LE_CDAT   <- eflalo$LE_CDAT[ match(tacsatp$FT_REF,eflalo$FT_REF)]
  tacsatp$VE_COU    <- eflalo$VE_COU[ match(tacsatp$FT_REF,eflalo$FT_REF)]


  #-------------------------------------------------------------------------------
  #- Save not merged tacsat data
  #-------------------------------------------------------------------------------
  tacsatpmin        <- subset(tacsatp,FT_REF == 0)
  save(tacsatpmin,file=paste(outPath,"tacsatNotMerged",year,".RData",sep=""))

  tacsatp           <- subset(tacsatp,FT_REF != 0)
  save(tacsatp,   file=paste(outPath,"tacsatMerged",year,".RData",   sep=""))

#-------------------------------------------------------------------------------
#- 5) Define activitity
#-------------------------------------------------------------------------------

  #- Calculate time interval between points
  tacsatp         <- intervalTacsat(tacsatp,level="trip",fill.na=T)
  #- Reset values that are simply too high to 2x the regular interval rate
  tacsatp$INTV[tacsatp$INTV>intvThres] <- 2*intvThres

  #-------------------------------------------------------------------------------
  #- Remove points with NA's in them in critial places
  #-------------------------------------------------------------------------------
  idx             <- which(is.na(tacsatp$VE_REF) == T   | is.na(tacsatp$SI_LONG) == T | is.na(tacsatp$SI_LATI) == T |
                           is.na(tacsatp$SI_DATIM) == T |  is.na(tacsatp$SI_SP) == T)
  if(length(idx)>0) tacsatp         <- tacsatp[-idx,]

  #-------------------------------------------------------------------------------
  #- Define speed thresholds associated with fishing for gears
  #-------------------------------------------------------------------------------

  #- Investigate speed pattern through visual inspection of histograms
  png(filename=file.path(outPath,paste("SpeedHistogram_",year,".png",sep="")))
  ggplot(data=tacsatp, aes(SI_SP)) +
  geom_histogram(breaks=seq(0, 20, by =0.4),
                 col=1)+
  facet_wrap(~LE_GEAR,ncol=4,scales="free_y")+
  labs(x = "Speed (knots)", y = "Frequency") +
                      theme(axis.text.y   = element_text(colour="black"),
                            axis.text.x   = element_text(colour="black"),
                            axis.title.y  = element_text(size=14),
                            axis.title.x  = element_text(size=14),
                            panel.background = element_blank(),
                            panel.grid.major = element_blank(),
                            panel.grid.minor = element_blank(),
                            axis.line = element_line(colour = "black"),
                            panel.border = element_rect(colour = "black", fill=NA))
  dev.off()
  #- Create speed threshold object
  speedarr          <- as.data.frame(cbind(LE_GEAR=sort(unique(tacsatp$LE_GEAR)),min=NA,max=NA),stringsAsFactors=F)
  speedarr$min      <- rep(1,nrow(speedarr)) # It is important to fill out the personally inspected thresholds here!
  speedarr$max      <- rep(6,nrow(speedarr))
  

  #-------------------------------------------------------------------------------
  #- Analyse activity automated for common gears only. Use the speedarr for the other gears
  #-------------------------------------------------------------------------------

  subTacsat                 <- subset(tacsatp,LE_GEAR %in% autoDetectionGears)
  nonsubTacsat              <- subset(tacsatp,!LE_GEAR %in% autoDetectionGears)

  if(visualInspection==T){
    storeScheme               <- activityTacsatAnalyse(subTacsat, units = "year", analyse.by = "LE_GEAR",identify="means")
  } else {

    storeScheme               <- expand.grid(years = year, months = 0,weeks = 0,
                                             analyse.by = unique(subTacsat[,"LE_GEAR"]))
    storeScheme$peaks         <- NA
    storeScheme$means         <- NA
    storeScheme$fixPeaks      <- FALSE
    storeScheme$sigma0        <- 0.911

    #-------------------------------------------------------------------------------
    #- Fill the storeScheme values based on analyses of the pictures
    #-------------------------------------------------------------------------------

    #- Define mean values of the peaks and the number of peaks when they are different from 5
    storeScheme$means[which(storeScheme$analyse.by == "TBB")]       <- c("-11.5 -6 0 6 11.5")
    storeScheme$means[which(storeScheme$analyse.by == "OTB")]       <- c("-9 -3 0 3 9")
    storeScheme$means[which(storeScheme$analyse.by == "OTT")]       <- c("-9 -3 0 3 9")
    storeScheme$means[which(storeScheme$analyse.by == "SSC")]       <- c("-9 0 9")
    storeScheme$means[which(storeScheme$analyse.by == "PTB")]       <- c("-10 -3 0 3 10")
    storeScheme$means[which(storeScheme$analyse.by == "DRB")]       <- c("-10 0 10")
    storeScheme$means[which(storeScheme$analyse.by == "HMD")]       <- c("-9 0 9")
    storeScheme$peaks[which(storeScheme$analyse.by == "SSC")]       <- 3
    storeScheme$peaks[which(storeScheme$analyse.by == "DRB")]       <- 3
    storeScheme$peaks[which(storeScheme$analyse.by == "HMD")]       <- 3
    storeScheme$peaks[which(is.na(storeScheme$peaks) == TRUE)]      <- 5
  }
  
  acTa                      <- activityTacsat(subTacsat,units="year",analyse.by="LE_GEAR",
                                              storeScheme=storeScheme,plot=FALSE,level="all")
  subTacsat$SI_STATE        <- acTa
  subTacsat$ID              <- 1:nrow(subTacsat)
  
  #- Check results, and if results are not satisfactory, run analyses again but now
  #   with fixed peaks
  for(iGear in autoDetectionGears){
    subDat    <- subset(subTacsat,LE_GEAR == iGear)
    minS      <- min(subDat$SI_SP[which(subDat$SI_STATE == "s")],na.rm=T)
    minF      <- min(subDat$SI_SP[which(subDat$SI_STATE == "f")],na.rm=T)
    if(minS < minF){
      storeScheme$fixPeaks[which(storeScheme$analyse.by == iGear)]   <- TRUE
      subacTa <- activityTacsat(subDat,units="year",analyse.by="LE_GEAR",storeScheme,plot=FALSE,level="all")
      subTacsat$SI_STATE[subDat$ID] <- subacTa
    }
  }
  subTacsat   <- subTacsat[,-rev(grep("ID",colnames(subTacsat)))[1]]

  #-------------------------------------------------------------------------------
  #- Assign for visually inspected gears a simple speed rule classification
  #-------------------------------------------------------------------------------

  metiers                   <- unique(nonsubTacsat$LE_GEAR)
  nonsubTacsat$SI_STATE     <- NA
  for (mm in metiers) {
    nonsubTacsat$SI_STATE[nonsubTacsat$LE_GEAR==mm & nonsubTacsat$SI_SP >= speedarr[speedarr$LE_GEAR==mm,"min"] & nonsubTacsat$SI_SP <= speedarr[speedarr$LE_GEAR==mm,"max"]]   <- "f";
  }
  nonsubTacsat$SI_STATE[nonsubTacsat$LE_GEAR=="NA" & nonsubTacsat$SI_SP >= speedarr[speedarr$LE_GEAR=="MIS","min"] & nonsubTacsat$SI_SP <= speedarr[speedarr$LE_GEAR=="MIS","max"]]   <- "f"
  nonsubTacsat$SI_STATE[is.na(nonsubTacsat$SI_STATE)] <- "s"

  #-------------------------------------------------------------------------------
  #- Combine the two dataset together again
  #-------------------------------------------------------------------------------
  tacsatp                   <- rbindTacsat(subTacsat,nonsubTacsat)
  tacsatp                   <- orderBy(~VE_REF+SI_DATIM,data=tacsatp)
  #- Set fishing sequences with hauling in the middle to "f"
  idx                       <- which(tacsatp$SI_STATE[2:(nrow(tacsatp)-1)] == "h" &
                                     tacsatp$SI_STATE[1:(nrow(tacsatp)-2)] == "f" &
                                     tacsatp$SI_STATE[3:(nrow(tacsatp))  ] == "f" &
                                     tacsatp$VE_REF[2:(nrow(tacsatp)-1)]   == tacsatp$VE_REF[1:(nrow(tacsatp)-2)] &
                                     tacsatp$VE_REF[2:(nrow(tacsatp)-1)]   == tacsatp$VE_REF[3:(nrow(tacsatp))])+1
  tacsatp$SI_STATE[idx]     <- "f"

  save(tacsatp,file=file.path(outPath,paste("tacsatActivity",year,".RData",sep="")))

  print("Defining activity completed")
#-------------------------------------------------------------------------------
#- 6) Dispatch landings of merged eflalo at the ping scale
#-------------------------------------------------------------------------------
  idxkgeur          <- kgeur(colnames(eflalo))
  eflalo$LE_KG_TOT  <- rowSums(eflalo[,grep("LE_KG_",colnames(eflalo))],na.rm=T)
  eflalo$LE_EURO_TOT<- rowSums(eflalo[,grep("LE_EURO_",colnames(eflalo))],na.rm=T)
  eflalo            <- eflalo[,-idxkgeur]
  eflaloNM          <- subset(eflalo,!FT_REF %in% unique(tacsatp$FT_REF))
  eflaloM           <- subset(eflalo,FT_REF %in% unique(tacsatp$FT_REF))

  tacsatp$SI_STATE[which(tacsatp$SI_STATE != "f")] <- 0
  tacsatp$SI_STATE[which(tacsatp$SI_STATE == "f")] <- 1

  #- There are several options, specify at the top of this script what type of linking you require
  if(!"trip" %in% linkTacsatEflalo) stop("trip must be in linkTacsatEflalo")
  if(all(c("day","ICESrectangle","trip") %in% linkEflaloTacsat)){
    tacsatEflalo  <- splitAmongPings(tacsat=tacsatp,eflalo=eflaloM,variable="all",level="day",conserve=T)
  } else {
    if(all(c("day","trip") %in% linkEflaloTacsat) & !"ICESrectangle" %in% linkEflaloTacsat){
      tmpTa       <- tacsatp
      tmpEf       <- eflaloM
      tmpTa$LE_RECT <- "ALL"
      tmpEf$LE_RECT <- "ALL"
      tacsatEflalo  <- splitAmongPings(tacsat=tmpTa,eflalo=tmpEf,variable="all",level="day",conserve=T)
    } else {
      if(all(c("ICESrectangle","trip") %in% linkEflaloTacsat) & !"day" %in% linkEflaloTacsat){
        tacsatEflalo  <- splitAmongPings(tacsat=tacsatp,eflalo=eflaloM,variable="all",level="ICESrectangle",conserve=T)
      } else {
        if(linkEflaloTacsat == "trip" & length(linkEflaloTacsat)==1){
          tacsatEflalo  <- splitAmongPings(tacsat=tacsatp,eflalo=eflaloM,variable="all",level="trip",conserve=T)
        }
      }
    }
  }

  save(tacsatEflalo,file=paste(outPath,"tacsatEflalo",year,".RData",sep=""))

  print("Dispatching landings completed")

#-------------------------------------------------------------------------------
#- 7) Assign c-square, year, month, quarter, area and create table 1
#-------------------------------------------------------------------------------

  tacsatEflalo$Csquare  <- CSquare(tacsatEflalo$SI_LONG,tacsatEflalo$SI_LATI,degrees=0.05)
  tacsatEflalo$Year     <- year(tacsatEflalo$SI_DATIM)
  tacsatEflalo$Month    <- month(tacsatEflalo$SI_DATIM)
  tacsatEflalo$kwHour   <- tacsatEflalo$VE_KW * tacsatEflalo$INTV/60
  tacsatEflalo$INTV     <- tacsatEflalo$INTV/60
  tacsatEflalo$LENGTHCAT<- cut(tacsatEflalo$VE_LEN,breaks=c(0,8,10,12,15,200))
  tacsatEflalo$LENGTHCAT<- ac(tacsatEflalo$LENGTHCAT)
  tacsatEflalo$LENGTHCAT[which(tacsatEflalo$LENGTHCAT == "(0,8]")]   <- "<8"
  tacsatEflalo$LENGTHCAT[which(tacsatEflalo$LENGTHCAT == "(8,10]")]   <- "8-10"
  tacsatEflalo$LENGTHCAT[which(tacsatEflalo$LENGTHCAT == "(10,12]")]   <- "10-12"
  tacsatEflalo$LENGTHCAT[which(tacsatEflalo$LENGTHCAT == "(12,15]")]  <- "12-15"
  tacsatEflalo$LENGTHCAT[which(tacsatEflalo$LENGTHCAT == "(15,200]")] <- ">15"

  RecordType <- "VE"
  
  if(year == yearsToSubmit[1]){
    table1                <- cbind(RT=RecordType,tacsatEflalo[,c("VE_COU","Year","Month","Csquare","LENGTHCAT","LE_GEAR","LE_MET","SI_SP","INTV","VE_LEN","kwHour","VE_KW","LE_KG_TOT","LE_EURO_TOT")])
  } else {
      table1              <- rbind(table1,
                                   cbind(RT=RecordType,tacsatEflalo[,c("VE_COU","Year","Month","Csquare","LENGTHCAT","LE_GEAR","LE_MET","SI_SP","INTV","VE_LEN","kwHour","VE_KW","LE_KG_TOT","LE_EURO_TOT")]))
    }
  table1Sums              <- aggregate(table1[,c("INTV","kwHour","LE_KG_TOT","LE_EURO_TOT")],
                                       by=as.list(table1[,c("RT","VE_COU","Year","Month","Csquare","LENGTHCAT","LE_GEAR","LE_MET")]),
                                       FUN=sum,na.rm=T)
  table1Means             <- aggregate(table1[,c("SI_SP","VE_LEN","VE_KW")],
                                       by=as.list(table1[,c("RT","VE_COU","Year","Month","Csquare","LENGTHCAT","LE_GEAR","LE_MET")]),
                                       FUN=mean,na.rm=T)
  table1Save              <- cbind(table1Sums,table1Means[,c("SI_SP","VE_LEN","VE_KW")])
  colnames(table1Save)    <- c("RecordType","VesselFlagCountry","Year","Month","C-square","LengthCat","Gear","Europeanlvl6","Fishing hour","KWhour","TotWeight","TotEuro","Av fish speed","Av vessel length","Av vessel KW")
  

#-------------------------------------------------------------------------------
#- 8) Assign  year, month, quarter, area and create table 2
#-------------------------------------------------------------------------------

  eflalo$Year             <- year(eflalo$FT_LDATIM)
  eflalo$Month            <- month(eflalo$FT_LDATIM)
  eflalo$INTV             <- 1 #1 day
  eflalo$dummy            <- 1
  res                     <- aggregate(eflalo$dummy,by=as.list(eflalo[,c("VE_COU","VE_REF","LE_CDAT")]),FUN=sum,na.rm=T)
  colnames(res)           <- c("VE_COU","VE_REF","LE_CDAT","nrRecords")
  eflalo                  <- merge(eflalo,res,by=c("VE_COU","VE_REF","LE_CDAT"))
  eflalo$INTV             <- eflalo$INTV / eflalo$nrRecords
  eflalo$kwDays           <- eflalo$VE_KW * eflalo$INTV
  eflalo$tripInTacsat     <- ifelse(eflalo$FT_REF %in% tacsatp$FT_REF,"Yes","No")

  eflalo$LENGTHCAT        <- cut(eflalo$VE_LEN,breaks=c(0,8,10,12,15,200))
  eflalo$LENGTHCAT        <- ac(eflalo$LENGTHCAT)
  eflalo$LENGTHCAT[which(eflalo$LENGTHCAT == "(0,8]")]   <- "<8"
  eflalo$LENGTHCAT[which(eflalo$LENGTHCAT == "(8,10]")]  <- "8-10"
  eflalo$LENGTHCAT[which(eflalo$LENGTHCAT == "(10,12]")]  <- "10-12"
  eflalo$LENGTHCAT[which(eflalo$LENGTHCAT == "(12,15]")]  <- "12-15"
  eflalo$LENGTHCAT[which(eflalo$LENGTHCAT == "(15,200]")] <- ">15"

  RecordType <- "LE"

  if(year == yearsToSubmit[1]){
    table2                <- cbind(RT=RecordType,eflalo[,c("VE_COU","Year","Month","LE_RECT","LE_GEAR","LE_MET","LENGTHCAT","tripInTacsat","INTV","kwDays","LE_KG_TOT","LE_EURO_TOT")])
  } else {
      table2              <- rbind(table2,
                                   cbind(RT=RecordType,eflalo[,c("VE_COU","Year","Month","LE_RECT","LE_GEAR","LE_MET","LENGTHCAT","tripInTacsat","INTV","kwDays","LE_KG_TOT","LE_EURO_TOT")]))
    }
  table2Save              <- aggregate(table2[,c("INTV","kwDays","LE_KG_TOT","LE_EURO_TOT")],
                                       by=as.list(table2[,c("RT","VE_COU","Year","Month","LE_RECT","LE_GEAR","LE_MET","LENGTHCAT","tripInTacsat")]),
                                       FUN=sum,na.rm=T)
  colnames(table2Save)    <- c("RecordType","VesselFlagCountry","Year","Month","ICESrect","Gear","Europeanlvl6","LengthCat","VMS enabled","FishingDays","KWDays","TotWeight","TotValue")
}

write.csv(table1Save,file=file.path(outPath,"table1.csv"))
write.csv(table2Save,file=file.path(outPath,"table2.csv"))