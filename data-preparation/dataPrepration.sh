#!/bin/bash

W_DIR=/cs/natlang-projects/users/maryam/wikiCrawler/testPipline
NER_HOME=/cs/natlang-projects/users/maryam/clustering/NERStanford
UIUC_Dir=/cs/natlang-sw/Linux-x86_64/NL/TOOLKITS/UIUCSRL/2.0/
PYPATH=/cs/natlang-sw/Linux-x86_64/NL/LANG/PYTHON/2.7.3/bin/python

module load NL/LANG/PYTHON/2.7.3
module load NL/TOOLKITS/UIUCSRL/2.0

cd $W_DIR

### STEP 1: crawling the main domain ###
########################################
echo "Running eventSpider to crawl wiki articles"
scrapy runspider -a outfile='response.json' -a endYear='2013' spiders/eventSpider.py


### STEP 2: Running NER ###
###########################

echo "Extracting description parts and write in: eventDescription.txt"
$PYPATH xtrctTxtForNER.py response.json
# eventDescription.txt: all event descriptions (seperated by a symbol "PAR_SPLITTER_SYMBOL")

ndesc=`wc -l eventDescription.txt | cut -d' ' -f1`
nsent=50000
npart=`echo "$ndesc / $nsent" | bc`

echo "$ndesc total descriptions (including splitter symboles)"
echo "Dividing descriptions to files of $nsent lines and running NER"

log=nerLogFiles
mkdir -p $log
lastInd=-1
for (( i=0; i<$npart; i++ )); do
     let s="i * $nsent + 1"
     let t="( i + 1 ) * $nsent"
     sed -n "${s},${t}p" eventDescription.txt > $log/part.$i
     java -mx600m -cp "$NER_HOME/stanford-ner.jar" edu.stanford.nlp.ie.crf.CRFClassifier -loadClassifier $NER_HOME/classifiers/english.conll.4class.distsim.crf.ser.gz -textFile $log/part.$i > $log/part.ner.$i
     lastInd=$i
done
let tot="$npart * $nsent"
let remaining="$ndesc - $tot"
let lastInd="$lastInd + 1"
echo $remaining
if [ $remaining -gt 0 ]; then
        tail -$remaining eventDescription.txt > $log/part.$lastInd
        java -mx600m -cp "$NER_HOME/stanford-ner.jar" edu.stanford.nlp.ie.crf.CRFClassifier -loadClassifier $NER_HOME/classifiers/english.conll.4class.distsim.crf.ser.gz -textFile $log/part.$lastInd > $log/part.ner.$lastInd
        let npart="$npart + 1"
fi

echo "Concatinating ner files to \"eventDescription.ner\""
cat $log/part.ner.0 > eventDescription.ner
for (( i=1; i<$npart; i++ )); do
	cat $log/part.ner.$i >> eventDescription.ner
done

echo "Extracting locations recognized by NER (\"locFromNER.txt\") and tokenized descriptions (\"eventDescription.ner.tok\") to run SRL"
$PYPATH getTxtFromNER.py eventDescription.ner NER	
#eventDescription.ner.tok:	each line is one event (tokenized)
#NER.loc: 		each line is a location predicted by NER
#NER.person: 		each line is a person predicted by NER


### STEP 3: Extract location inforamtion ###
############################################

cd $W_DIR

echo "Running locationSpider to crawl all links and specified locations"
scrapy runspider -a infile='response.json' -a outfileLoc='location.json' -a outfilePer='person.json' spiders/entitySpider.py
echo "Running nerLocSpider to crawl corresponding wiki articles and recognize locations"
scrapy runspider -a infile='NER.loc' -a outfile='locFromNER.json' spiders/nerLocSpider.py
echo "Running nerPersonSpider to crawl corresponding wiki articles and recognize persons"
scrapy runspider -a infile='NER.person' -a outfile='perFromNER.json' spiders/nerPersonSpider.py

echo "Combining all location information (from NER and wiki links in descriptions)"
$PYPATH makeLocationDict.py location.json locFromNER.json txturl2latlong.json
#locationDictionary.txt: is a dictionary file from url or text to latitude longtitue. the format of each line is:
#[text|url]\tlatitude , longtitude

echo "Combining all person information (from NER and wiki links in descriptions)"
$PYPATH makePersonDict.py person.json perFromNER.json personDictionary.json
#personDictionary.txt: is a dictionary file from url or text to name (of person). the format of each line is:
#[text|url]\tPersonName


### STEP 4: Reverse Geocoding ###
#################################

# We use google geocoding (reverseGeocoding.sh) which currently has a limitation on number of queries per day.
# Therefore you should run it seperately and prepare a file contains all locations ("locationDictionary.json") 
#using txturl2latlong.txt, and use it to prepare final json file.

$PYPATH findNewLocations.py txturl2latlong.json locationDictionary.json newLocations.json

sh ./reverseGeocoding.sh newLocations.json

if [ -f locationDictionary.json.cln ] && [ -f newLocationsCountry.json ];
then
cat locationDictionary.json.cln > locationDictionary.json
cat newLocationsCountry.json >> locationDictionary.json
else
echo "err in preparing locationDictionary.json"
fi

### STEP 5: Running SRL ###
###########################

echo "Running UIUC SRL: input:eventDescription.ner.tok output:eventDescription.ner.tok.srl"

# Uncomment following lines to run the server

#cd $UIUC_DIR/CharniakServer
#nohup ./charniak-server.pl > charniak-server.log &
#cd $UIUC_DIR/bin
#./start-server.sh

cd $UIUC_DIR/bin
perl srl-client-primitive.pl 0 0 $W_DIR/eventDescription.ner.tok  $W_DIR/eventDescription.ner.tok.srl


### STEP 6: Prepare json file ###
#################################

#cd $W_DIR

#echo "Writing the final json file"

#$PYPATH prepareJson.py eventDescription.ner.tok.srl locationDictionary.json personDictionary.json response.json eventDescription.ner fullData.json
