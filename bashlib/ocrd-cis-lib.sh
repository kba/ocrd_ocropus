#!/bin/bash

set -e

ocrd-cis-log() {
	echo LOG: $* >&2
}

# utility function to join strings with a given string
function ocrd-cis-join-by { local IFS="$1"; shift; echo "$*"; }

# Parse command line arguments for a given argument and returns its
# value.  Usage: `ocrd-cis-getopt -P --parameter $*`.
ocrd-cis-getopt() {
	short=$1
	shift
	long=$1
	shift
	while [[ $# -gt 0 ]]; do
		case $1 in
			$short|$long) echo $2; return 0;;
			*) shift;;
		esac
	done
	ocrd-cis-log "missing command line argument: $short | $long"
	exit 1
}

# Download the ocrd.jar if it does not exist.
ocrd-cis-download-jar() {
	if [[ -f "$1" ]]; then
		return 0
	fi
	local jar=http://www.cis.lmu.de/~finkf/ocrd.jar
	local dir=$(/usr/bin/dirname $1)
	pushd $dir
	wget -N $jar || true
	popd
}

# Add OCR page XML and its image to the workspace. Usage:
# `ocrd-cis-add-pagexml-and-image-to-workspace workspace pagexmlfg
# pagexml imagefg image`.
ocrd-cis-add-pagexml-and-image-to-workspace() {
	local workspace=$1
	local pagexmlfg=$2
	local pagexml=$3
	local imagefg=$4
	local image=$5

	pushd "$workspace"
	# add image
	local mime=$(ocrd-cis-get-mimetype-by-extension $image)
	local fileid=$(basename $image)
	local addpath="$imagefg/$fileid"
	ocrd-cis-log ocrd workspace add --file-grp "$imagefg" --file-id "$fileid" --mimetype "$mime" "../$image"
	ocrd workspace add --file-grp "$imagefg" --file-id "$fileid" --mimetype "$mime" "../$image"

	# add page xml
	local mime=$(ocrd-cis-get-mimetype-by-extension $pagexml)
	local fileid=$(basename $pagexml)
	ocrd-cis-log ocrd workspace add --file-grp "$pagexmlfg" --file-id "$fileid" --mimetype "$mime" "../$pagexml"
	ocrd workspace add --file-grp "$pagexmlfg" --file-id "$fileid" --mimetype "$mime" "../$pagexml"

	# fix imageFilepath in page xml
	local absimgpath=$(realpath $addpath)
	sed -i "$pagexmlfg/$fileid" -e "s#imageFilename=\"[^\"]*\"#imageFilename=\"$absimgpath\"#"
	popd
}

ocrd-cis-get-mimetype-by-extension() {
	case $(echo $1 | tr '[:upper:]' '[:lower:]') in
		*.tif | *.tiff) echo "image/tif";;
		*.jpg | *.jpeg) echo "image/jpeg";;
		*.png) echo "image/png";;
		*.xml) echo "application/vnd.prima.page+xml";;
		*) echo "UNKWNON"
	esac
}

# Run multiple OCRs over a file group.  Usage: `ocrd-cis-run-ocr
# configfile mets ifg ofg`.  A XXX in the ofg is replaced with the
# ocr-type and number.  This function sets the global variable
# $OCRFILEGRPS to a space-separated list of the ocr output file
# groups.
ocrd-cis-run-ocr() {
	local config=$1
	local mets=$2
	local ifg=$3
	local ofg=$4
	OCRFILEGRPS=""

	for i in $(seq 0 $(cat "$config" | jq ".ocr | length-1")); do
		local type=$(cat "$config" | jq --raw-output ".ocr[$i].type")
		local path=$(cat "$config" | jq --raw-output ".ocr[$i].path")
		local utype=$(echo $type | tr '[:lower:]' '[:upper:]')
		local xofg=${ofg/XXX/$utype-$((i+1))}
		OCRFILEGRPS="$OCRFILEGRPS $xofg"
		case $utype in
			"OCROPY")
				ocrd-cis-log ocrd-cis-ocropy-recognize \
					--input-file-grp $ifg \
					--output-file-grp $xofg \
					--mets "$mets" \
					--parameter $path \
					--log-level $LOG_LEVEL
				ocrd-cis-ocropy-recognize \
					--input-file-grp $ifg \
					--output-file-grp $xofg \
					--mets "$mets" \
					--parameter $path \
					--log-level $LOG_LEVEL
				;;
			"TESSERACT")
				ocrd-cis-log ocrd-tesserocr-recognize \
					--input-file-grp $ifg \
					--output-file-grp $xofg \
					--mets "$mets" \
					--parameter $path \
					--log-level $LOG_LEVEL
				ocrd-tesserocr-recognize \
					--input-file-grp $ifg \
					--output-file-grp $xofg \
					--mets "$mets" \
					--parameter $path \
					--log-level $LOG_LEVEL
				;;
			*)
				echo "invalid ocr type: $utype"
				exit 1
				;;
		esac
	done
}

# Search for the associated image file for the given xml file in the
# given directory. The given xml file must end with .xml. Usage:
# `ocrd-cis-find-image-for-xml dir xy.xml`
ocrd-cis-find-image-for-xml() {
	local dir=$1
	local xml=$2

	for pre in .bin .dew ""; do # prefer binary before descewed before normal images
		for ext in .jpg .jpeg .JPG .JPEG .png .tiff; do
			local name=${xml/.xml/$pre$ext}
			local file=$(find $dir -type f -name $name)
			if [[ ! -z $file ]]; then
				ocrd-cis-log "[$xml]" found $file
				echo $file
				return 0
			fi
		done
	done
	return 1
}

# Add the content of a zip file to a workspace.  Usage:
# `ocrd-cis-add-zip-to-workspace zip workspace pxml-file-grp
# image-file-grp`
ocrd-cis-add-zip-to-workspace() {
	local zip=$1
	local workspace=$2
	local pfg=$3
	local ifg=$4

	unzip -u $zip
	for tif in $(find ${zip/.zip/} -type f -name '*.tif'); do
		echo tif: $tif
		dir=$(dirname "$tif")
		name=$(basename "$tif")
		name=${name/.tif/.xml}
		pxml="$dir/page/$name"
		echo $pxml $tif
		ocrd-cis-add-pagexml-and-image-to-workspace "$workspace" "$pfg" "$pxml" "$ifg" "$tif"
	done
}

# Given a directory add image and base xml files, run additional ocrs
# and align them.  Sets ALGINFILEGRP to the alignment file group.
# Usage: `ocrd-cis-run-ocr-and-align config mets dir fg gt`.
# * config	: path to the main config file
# * mets		: path to the mets file
# * dir		: path to the directory
# * fg		: base name of filegroups
# * gt		: gt=GT if xml files are ground truth; anythin else if not
ocrd-cis-run-ocr-and-align() {
	local config=$1
	local mets=$2
	local dir=$3
	local fg=$4
	local gt=$5

	for xml in $(find "$dir" -type f -name '.xml'); do
		if [[ "$xml" == "*alto*" ]]; then # skip alto xml files in gt archives
		   continue
		fi
		local img=$(ocrd-cis-find-image-for-xml "$pxml")
		local imgmt=$(ocrd-cis-get-mimetype-by-extension "$img")
		local xmlmt=$(ocrd-cis-get-mimetype-by-extension "$xml")
		ocrd workspace add \
			 --fileg-grp "OCR-D-IMG-$fg" \
			 --mimetype "$imgmt" \
			 --file-id "$(basename "$img")" \
			 --force "$img"
		ocrd workspace add \
			 --fileg-grp "OCR-D-$gt-$fg" \
			 --mimetype "$xmlmt" \
			 --file-id "$(basename "$xml")" \
			 --force "$xml"
	done
	OCRFILEGRPS=""
	ocrd-cis-run-ocr "$config" "$mets" "OCR-D-$gt-$fg" "OCR-D-XXX-$fg"
	if [[ $(tr '[[:upper:]]' '[[:lower:]]' "$gt") == "gt" ]]; then
		OCRFILEGRPS="$OCRFILEGRPS $OCR-D-$gt-$fg"
	else
		OCRFILEGRPS="$OCR-D-$gt-$fg $OCRFILEGRPS"
	fi
	OCRFILEGRPS=$(ocrd-cis-join-by , $OCRFILEGRPS)
	ALGINFILEGRP="OCR-D-ALIGN-$fg"
	ocrd-cis-align \
		--input-file-grp "$OCRFILEGRPS" \
		--output-file-grp "$ALIGNFILEGRP" \
		--mets "$mets" \
		--parameter $(cat "$config" | jq --raw-output ".alignparampath") \
		--log-level $LOG_LEVEL
}