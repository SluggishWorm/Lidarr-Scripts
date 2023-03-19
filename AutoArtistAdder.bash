#!/usr/bin/env bash
scriptVersion="1.0.008"
if [ -z "$lidarrUrl" ] || [ -z "$lidarrApiKey" ]; then
	lidarrUrlBase="$(cat /config/config.xml | xq | jq -r .Config.UrlBase)"
	if [ "$lidarrUrlBase" == "null" ]; then
		lidarrUrlBase=""
	else
		lidarrUrlBase="/$(echo "$lidarrUrlBase" | sed "s/\///g")"
	fi
	lidarrApiKey="$(cat /config/config.xml | xq | jq -r .Config.ApiKey)"
	lidarrPort="$(cat /config/config.xml | xq | jq -r .Config.Port)"
	lidarrUrl="http://127.0.0.1:${lidarrPort}${lidarrUrlBase}"
fi
agent="lidarr"
musicbrainzMirror=https://musicbrainz.org

# Debugging settings
#addRelatedArtists="true"
#addDeezerTopArtists="true"
#addDeezerTopAlbumArtists="true"
#addDeezerTopTrackArtists="true"
#topLimit="3"
#addRelatedArtists="true"
#numberOfRelatedArtistsToAddPerArtist="1"
#lidarrSearchForMissing=false


touch "/config/logs/AutoArtistAdder.txt"
chmod 666 "/config/logs/AutoArtistAdder.txt"
exec &> >(tee -a "/config/logs/AutoArtistAdder.txt")

sleepTimer=0.5

log () {
	m_time=`date "+%F %T"`
	echo $m_time" :: AutoArtistAdder :: $scriptVersion :: "$1
}

NotifyWebhook () {
	if [ "$webHook" ]
	then
		content="$1: $2"
		curl -s -X POST "{$webHook}" -H 'Content-Type: application/json' -d '{"event":"'"$1"'", "message":"'"$2"'", "content":"'"$content"'"}'
	fi
}

AddDeezerTopArtists () {
	getDeezerArtistsIds=$(curl -s "https://api.deezer.com/chart/0/artists?limit=$1" | jq -r ".data[].id")
	getDeezerArtistsIdsCount=$(echo "$getDeezerArtistsIds" | wc -l)
	getDeezerArtistsIds=($(echo "$getDeezerArtistsIds"))
	sleep $sleepTimer
	description="Top Artists"
	AddDeezerArtistToLidarr
}

AddDeezerTopAlbumArtists () {
	getDeezerArtistsIds=$(curl -s "https://api.deezer.com/chart/0/albums?limit=$1" | jq -r ".data[].artist.id")
	getDeezerArtistsIdsCount=$(echo "$getDeezerArtistsIds" | wc -l)
	getDeezerArtistsIds=($(echo "$getDeezerArtistsIds"))
	sleep $sleepTimer
	description="Top Album Artists"
	AddDeezerArtistToLidarr
}

AddDeezerTopTrackArtists () {
	getDeezerArtistsIds=$(curl -s "https://api.deezer.com/chart/0/tracks?limit=$1" | jq -r ".data[].artist.id")
	getDeezerArtistsIdsCount=$(echo "$getDeezerArtistsIds" | wc -l)
	getDeezerArtistsIds=($(echo "$getDeezerArtistsIds"))
	sleep $sleepTimer
	description="Top Track Artists"
	AddDeezerArtistToLidarr
}

AddDeezerArtistToLidarr () {
	lidarrArtistsData="$(curl -s "$lidarrUrl/api/v1/artist?apikey=${lidarrApiKey}")"
	lidarrArtistIds="$(echo "${lidarrArtistsData}" | jq -r ".[].foreignArtistId")"
	deezerArtistsUrl=$(echo "${lidarrArtistsData}" | jq -r ".[].links | .[] | select(.name==\"deezer\") | .url")
	deezerArtistIds="$(echo "$deezerArtistsUrl" | grep -o '[[:digit:]]*' | sort -u)"
	log "Finding $description..."
	log "$getDeezerArtistsIdsCount $description Found..."
	for id in ${!getDeezerArtistsIds[@]}; do
		currentprocess=$(( $id + 1 ))
		deezerArtistId="${getDeezerArtistsIds[$id]}"
		deezerArtistName="$(curl -s https://api.deezer.com/artist/$deezerArtistId | jq -r .name)"
		sleep $sleepTimer
		log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: Searching Musicbrainz for Deezer artist id ($deezerArtistId)"

		if echo "$deezerArtistIds" | grep "^${deezerArtistId}$" | read; then
			log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: $deezerArtistId already in Lidarr..."
			continue
		fi

		query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22https://www.deezer.com/artist/${deezerArtistId}%22&fmt=json")
		count=$(echo "$query_data" | jq -r ".count")
		if [ "$count" == "0" ]; then
			sleep 1.5
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22http://www.deezer.com/artist/${deezerArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
			sleep 1.5
		fi
							
		if [ "$count" == "0" ]; then
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22http://deezer.com/artist/${deezerArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
			sleep 1.5
		fi
							
		if [ "$count" == "0" ]; then
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22https://deezer.com/artist/${deezerArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
		fi
							
		if [ "$count" != "0" ]; then
			musicbrainz_main_artist_id=$(echo "$query_data" | jq -r '.urls[]."relation-list"[].relations[].artist.id' | head -n 1)
			sleep 1.5
			artist_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/artist/$musicbrainz_main_artist_id?fmt=json")
			artist_sort_name="$(echo "$artist_data" | jq -r '."sort-name"')"
			artist_formed="$(echo "$artist_data" | jq -r '."begin-area".name')"
			artist_born="$(echo "$artist_data" | jq -r '."life-span".begin')"
			gender="$(echo "$artist_data" | jq -r ".gender")"
			matched_id=true
			data=$(curl -s "$lidarrUrl/api/v1/search?term=lidarr%3A$musicbrainz_main_artist_id" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[]")
			artistName="$(echo "$data" | jq -r ".artist.artistName")"
			foreignId="$(echo "$data" | jq -r ".foreignId")"
			importListExclusionData=$(curl -s "$lidarrUrl/api/v1/importlistexclusion" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[].foreignId")
			if echo "$importListExclusionData" | grep "^${foreignId}$" | read; then
				log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: ERROR :: Artist is on import exclusion block list, skipping...."
				continue
			fi
			data=$(curl -s "$lidarrUrl/api/v1/rootFolder" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[]")
			path="$(echo "$data" | jq -r ".path")"
			path=$(echo $path | cut -d' ' -f1)
			qualityProfileId="$(echo "$data" | jq -r ".defaultQualityProfileId")"
			qualityProfileId=$(echo $qualityProfileId | cut -d' ' -f1)
			metadataProfileId="$(echo "$data" | jq -r ".defaultMetadataProfileId")"
			metadataProfileId=$(echo $metadataProfileId | cut -d' ' -f1)
			data="{
				\"artistName\": \"$artistName\",
				\"foreignArtistId\": \"$foreignId\",
				\"qualityProfileId\": $qualityProfileId,
				\"metadataProfileId\": $metadataProfileId,
				\"monitored\":true,
				\"monitor\":\"all\",
				\"rootFolderPath\": \"$path\",
				\"addOptions\":{\"searchForMissingAlbums\":$lidarrSearchForMissing}
				}"
			if echo "$lidarrArtistIds" | grep "^${musicbrainz_main_artist_id}$" | read; then
				log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: Already in Lidarr ($musicbrainz_main_artist_id), skipping..."
				continue
			fi
			log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: Adding $artistName to Lidarr ($musicbrainz_main_artist_id)..."
			LidarrTaskStatusCheck
			lidarrAddArtist=$(curl -s "$lidarrUrl/api/v1/artist" -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $lidarrApiKey" --data-raw "$data")
		else
			log "$currentprocess of $getDeezerArtistsIdsCount :: $deezerArtistName :: Artist not found in Musicbrainz, please add \"https://deezer.com/artist/${deezerArtistId}\" to the correct artist on Musicbrainz"
			NotifyWebhook "ArtistError" "Artist not found in Musicbrainz, please add <https://deezer.com/artist/${deezerArtistId}> to the correct artist on Musicbrainz"
		fi
		LidarrTaskStatusCheck
	done
}


AddDeezerRelatedArtists () {
	log "Begin adding Lidarr related Artists from Deezer..."
	lidarrArtistsData="$(curl -s "$lidarrUrl/api/v1/artist?apikey=${lidarrApiKey}")"
	lidarrArtistTotal=$(echo "${lidarrArtistsData}"| jq -r '.[].sortName' | wc -l)
	lidarrArtistList=($(echo "${lidarrArtistsData}" | jq -r ".[].foreignArtistId"))
	lidarrArtistIds="$(echo "${lidarrArtistsData}" | jq -r ".[].foreignArtistId")"
	lidarrArtistLinkDeezerIds="$(echo "${lidarrArtistsData}" | jq -r ".[] | .links[] | select(.name==\"deezer\") | .url" | grep -o '[[:digit:]]*')"
	log "$lidarrArtistTotal Artists Found"
	deezerArtistsUrl=$(echo "${lidarrArtistsData}" | jq -r ".[].links | .[] | select(.name==\"deezer\") | .url")
	deezerArtistIds="$(echo "$deezerArtistsUrl" | grep -o '[[:digit:]]*' | sort -u)"

	for id in ${!lidarrArtistList[@]}; do
		artistNumber=$(( $id + 1 ))
		musicbrainzId="${lidarrArtistList[$id]}"
		lidarrArtistData=$(echo "${lidarrArtistsData}" | jq -r ".[] | select(.foreignArtistId==\"${musicbrainzId}\")")
		lidarrArtistName="$(echo "${lidarrArtistData}" | jq -r " .artistName")"
		deezerArtistUrl=$(echo "${lidarrArtistData}" | jq -r ".links | .[] | select(.name==\"deezer\") | .url")
		deezerArtistIds=($(echo "$deezerArtistUrl" | grep -o '[[:digit:]]*' | sort -u))
		lidarrArtistMonitored=$(echo "${lidarrArtistData}" | jq -r ".monitored")
		log "$artistNumber of $lidarrArtistTotal :: $wantedAlbumListSource :: $lidarrArtistName :: Adding Related Artists..."
		if [ "$lidarrArtistMonitored" == "false" ]; then
			log "$artistNumber of $lidarrArtistTotal :: $wantedAlbumListSource :: $lidarrArtistName :: Artist is not monitored :: skipping..."
			continue
		fi

		for dId in ${!deezerArtistIds[@]}; do
			deezerArtistId="${deezerArtistIds[$dId]}"
			deezerRelatedArtistData=$(curl -sL --fail "https://api.deezer.com/artist/$deezerArtistId/related?limit=$numberOfRelatedArtistsToAddPerArtist"| jq -r ".data | sort_by(.nb_fan) | reverse | .[]")
			sleep $sleepTimer
			getDeezerArtistsIds=($(echo $deezerRelatedArtistData | jq -r .id))
			getDeezerArtistsIdsCount=$(echo $deezerRelatedArtistData | jq -r .id | wc -l)
			description="$lidarrArtistName Related Artists"
			AddDeezerArtistToLidarr			
		done
	done
}

LidarrTaskStatusCheck () {
	alerted=no
	until false
	do
		taskCount=$(curl -s "$lidarrUrl/api/v1/command?apikey=${lidarrApiKey}" | jq -r .[].status | grep -v completed | grep -v failed | wc -l)
		if [ "$taskCount" -ge "1" ]; then
			if [ "$alerted" == "no" ]; then
				alerted=yes
				log "STATUS :: LIDARR BUSY :: Pausing/waiting for all active Lidarr tasks to end..."
			fi
			sleep 2
		else
			break
		fi
	done
}

AddTidalRelatedArtists () {
	log "Begin adding Lidarr related Artists from Tidal..."
	lidarrArtistsData="$(curl -s "$lidarrUrl/api/v1/artist?apikey=${lidarrApiKey}")"
	lidarrArtistTotal=$(echo "${lidarrArtistsData}"| jq -r '.[].sortName' | wc -l)
	lidarrArtistList=($(echo "${lidarrArtistsData}" | jq -r ".[].foreignArtistId"))
	lidarrArtistIds="$(echo "${lidarrArtistsData}" | jq -r ".[].foreignArtistId")"
	lidarrArtistLinkTidalIds="$(echo "${lidarrArtistsData}" | jq -r ".[] | .links[] | select(.name==\"tidal\") | .url" | grep -o '[[:digit:]]*' | sort -u)"
	log "$lidarrArtistTotal Artists Found"

	for id in ${!lidarrArtistList[@]}; do
		artistNumber=$(( $id + 1 ))
		musicbrainzId="${lidarrArtistList[$id]}"
		lidarrArtistData=$(echo "${lidarrArtistsData}" | jq -r ".[] | select(.foreignArtistId==\"${musicbrainzId}\")")
		lidarrArtistName="$(echo "${lidarrArtistData}" | jq -r " .artistName")"
		serviceArtistUrl=$(echo "${lidarrArtistData}" | jq -r ".links | .[] | select(.name==\"tidal\") | .url")
		serviceArtistIds=($(echo "$serviceArtistUrl" | grep -o '[[:digit:]]*' | sort -u))
		lidarrArtistMonitored=$(echo "${lidarrArtistData}" | jq -r ".monitored")
		log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: Adding Related Artists..."
		if [ "$lidarrArtistMonitored" == "false" ]; then
			log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: Artist is not monitored :: skipping..."
			continue
		fi
		
		for Id in ${!serviceArtistIds[@]}; do
			serviceArtistId="${serviceArtistIds[$Id]}"
			serviceRelatedArtistData=$(curl -sL --fail "https://api.tidal.com/v1/pages/single-module-page/ae223310-a4c2-4568-a770-ffef70344441/4/b4b95795-778b-49c5-a34f-59aac055b662/1?artistId=$serviceArtistId&countryCode=$tidalCountryCode&deviceType=BROWSER" -H 'x-tidal-token: CzET4vdadNUFQ5JU' | jq -r .rows[].modules[].pagedList.items[])
			sleep $sleepTimer
			serviceRelatedArtistsIds=($(echo $serviceRelatedArtistData | jq -r .id))
			serviceRelatedArtistsIdsCount=$(echo $serviceRelatedArtistData | jq -r .id | wc -l)
			log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $serviceArtistId :: Found $serviceRelatedArtistsIdsCount Artists, adding $numberOfRelatedArtistsToAddPerArtist..."
			AddTidalArtistToLidarr	
		done
	done
}

AddTidalArtistToLidarr () {
	currentprocess=0
	for id in ${!serviceRelatedArtistsIds[@]}; do
		currentprocess=$(( $id + 1 ))
		if [ $currentprocess -gt $numberOfRelatedArtistsToAddPerArtist ]; then
			break
		fi
		serviceArtistId="${serviceRelatedArtistsIds[$id]}"
		serviceArtistName="$(echo "$serviceRelatedArtistData"| jq -r "select(.id==$serviceArtistId) | .name")"
		log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: Searching Musicbrainz for Tidal artist id ($serviceArtistId)"

		if echo "$lidarrArtistLinkTidalIds" | grep "^${serviceArtistId}$" | read; then
			log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: $serviceArtistId already in Lidarr..."
			continue
		fi

		query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22https://listen.tidal.com/artist/${serviceArtistId}%22&fmt=json")
		count=$(echo "$query_data" | jq -r ".count")
		if [ "$count" == "0" ]; then
			sleep 1.5
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22http://listen.tidal.com/artist/${serviceArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
		fi
							
		if [ "$count" == "0" ]; then
			sleep 1.5
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22https://tidal.com/artist/${serviceArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
		fi
							
		if [ "$count" == "0" ]; then
			sleep 1.5
			query_data=$(curl -s -A "$agent" "https://musicbrainz.org/ws/2/url?query=url:%22http://tidal.com/artist/${serviceArtistId}%22&fmt=json")
			count=$(echo "$query_data" | jq -r ".count")
		fi
							
		if [ "$count" != "0" ]; then
			musicbrainz_main_artist_id=$(echo "$query_data" | jq -r '.urls[]."relation-list"[].relations[].artist.id' | head -n 1)
			data=$(curl -s "$lidarrUrl/api/v1/search?term=lidarr%3A$musicbrainz_main_artist_id" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[]")
			artistName="$(echo "$data" | jq -r ".artist.artistName")"
			foreignId="$(echo "$data" | jq -r ".foreignId")"
			importListExclusionData=$(curl -s "$lidarrUrl/api/v1/importlistexclusion" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[].foreignId")
			if echo "$importListExclusionData" | grep "^${foreignId}$" | read; then
				log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: ERROR :: Artist is on import exclusion block list, skipping...."
				continue
			fi
			data=$(curl -s "$lidarrUrl/api/v1/rootFolder" -H "X-Api-Key: $lidarrApiKey" | jq -r ".[]")
			path="$(echo "$data" | jq -r ".path")"
			path=$(echo $path | cut -d' ' -f1)
			qualityProfileId="$(echo "$data" | jq -r ".defaultQualityProfileId")"
			qualityProfileId=$(echo $qualityProfileId | cut -d' ' -f1)
			metadataProfileId="$(echo "$data" | jq -r ".defaultMetadataProfileId")"
			metadataProfileId=$(echo $metadataProfileId | cut -d' ' -f1)
			data="{
				\"artistName\": \"$artistName\",
				\"foreignArtistId\": \"$foreignId\",
				\"qualityProfileId\": $qualityProfileId,
				\"metadataProfileId\": $metadataProfileId,
				\"monitored\":true,
				\"monitor\":\"all\",
				\"rootFolderPath\": \"$path\",
				\"addOptions\":{\"searchForMissingAlbums\":$lidarrSearchForMissing}
				}"
			if echo "$lidarrArtistIds" | grep "^${musicbrainz_main_artist_id}$" | read; then
				log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: Already in Lidarr ($musicbrainz_main_artist_id), skipping..."
				continue
			fi
			log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: Adding $artistName to Lidarr ($musicbrainz_main_artist_id)..."
			LidarrTaskStatusCheck
			lidarrAddArtist=$(curl -s "$lidarrUrl/api/v1/artist" -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $lidarrApiKey" --data-raw "$data")
		else
			log "$artistNumber of $lidarrArtistTotal :: $lidarrArtistName :: $currentprocess of $numberOfRelatedArtistsToAddPerArtist :: $serviceArtistName :: ERROR :: Artist not found in Musicbrainz, please add \"https://listen.tidal.com/artist/${serviceArtistId}\" to the correct artist on Musicbrainz"
			NotifyWebhook "ArtistError" "Artist not found in Musicbrainz, please add <https://listen.tidal.com/artist/${serviceArtistId}> to the correct artist on Musicbrainz"
		fi
		LidarrTaskStatusCheck
	done
}

if [ -z $lidarrSearchForMissing ]; then
	lidarrSearchForMissing=true
fi

if [ "$addDeezerTopArtists" == "true" ]; then
	AddDeezerTopArtists "$topLimit"
fi

if [ "$addDeezerTopAlbumArtists" == "true" ]; then
	AddDeezerTopAlbumArtists "$topLimit"
fi

if [ "$addDeezerTopTrackArtists" == "true" ]; then
	AddDeezerTopTrackArtists "$topLimit"
fi

if [ "$addRelatedArtists" == "true" ]; then
	AddDeezerRelatedArtists
	AddTidalRelatedArtists
fi

exit