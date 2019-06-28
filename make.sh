#/bin/bash

# Project OEM-GSI Porter by Erfan Abdi <erfangplus@gmail.com>

usage()
{
echo "Usage: $0 <Path to GSI system> <Firmware type> <Output type> [Output Dir]"
    echo -e "\tPath to GSI system: Mount GSI and set mount point"
    echo -e "\tFirmware type: Firmware mode"
    echo -e "\tOutput type: AB or A-Only"
    echo -e "\tOutput Dir: set output dir"
}

if [ "$3" == "" ]; then
    echo "ERROR: Enter all needed parameters"
    usage
    exit 1
fi

LOCALDIR=`cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd`
sourcepath=$1
romtype=$2
outputtype=$3

if [[ $romtype == *":"* ]]; then
    romtypename=`echo "$romtype" | cut -d ":" -f 2`
    romtype=`echo "$romtype" | cut -d ":" -f 1`
else
    romtypename=$romtype
fi

flag=false
roms=("$LOCALDIR"/roms/*/*)
for dir in "${roms[@]}"
do
    rom=`echo "$dir" | rev | cut -d "/" -f 1 | rev`
    if [ "$rom" == "$romtype" ]; then
        flag=true
    fi
done
if [ "$flag" == "false" ]; then
    echo "$romtype is not supported rom, supported roms:"
    for dir in "${roms[@]}"
    do
        ver=`echo "$dir" | rev | cut -d "/" -f 2 | rev`
        rom=`echo "$dir" | rev | cut -d "/" -f 1 | rev`
        echo "$rom for Android $ver"
    done
    exit 1
fi
flag=false
case "$outputtype" in
    *"AB"*) flag=true7z ;;
    *"Aonly"*) flag=true7z ;;
esac
if [ "$flag" == "false" ]; then
    echo "$outputtype is not supported type, supported types:"
    echo "AB"
    echo "Aonly"
    exit 1
fi

# Detect Source type, AB or not
sourcetype="Aonly"
if [[ -e "$sourcepath/init.rc" ]]; then
    sourcetype="AB"
fi

erfanrun()
{
    # Only run if this romtype has those patch
    if [ -f $1 ]; then
    $1 $2
    fi
}

tempdirname="tmp"
tempdir="$LOCALDIR/$tempdirname"
systemdir="$tempdir/system"
toolsdir="$LOCALDIR/tools"
romsdir="$LOCALDIR/roms"
prebuiltdir="$LOCALDIR/prebuilt"
scriptsdir="$LOCALDIR/scripts"

echo "Create Temp dir"
mkdir -p "$systemdir"

if [ "$sourcetype" == "Aonly" ]; then
    echo "Warning: Aonly source detected, using P AOSP rootdir"
    cd "$systemdir"
    tar xf "$prebuiltdir/ABrootDir.tar"
    cd "$LOCALDIR"
    echo "Making copy of source rom to temp"
    ( cd "$sourcepath" ; sudo tar cf - . ) | ( cd "$systemdir/system" ; sudo tar xf - )
    cd "$LOCALDIR"
else
    echo "Making copy of source rom to temp"
    ( cd "$sourcepath" ; sudo tar cf - . ) | ( cd "$systemdir" ; sudo tar xf - )
    cd "$LOCALDIR"
fi

# Detect is the src treble ro.treble.enabled=true
istreble=`cat $systemdir/system/build.prop | grep ro.treble.enabled | cut -d "=" -f 2`
if [[ ! "$istreble" == "true" ]]; then
    echo "The source is not treble supported"
    exit 1
fi

# Detect Source API level
sourcever=`cat $systemdir/system/build.prop | grep ro.build.version.release | cut -d "=" -f 2`
flag=false
case "$sourcever" in
    *"9"*) flag=true7z ;;
    *"10"*) flag=true7z ;;
esac
if [ "$flag" == "false" ]; then
    echo "$sourcever is not supported"
    exit 1
fi

# Detect rom folder again
if [[ ! -d "$romsdir/$sourcever/$romtype" ]]; then
    echo "$romtype is not supported rom for android $sourcever"
    exit 1
fi

# Detect arch
if [[ ! -d "$systemdir/system/lib64" ]]; then
    echo "32bit source detected, weird flex but ok!"
    # do something here?
fi

# Debloat
erfanrun $romsdir/$sourcever/$romtype/debloat.sh "$systemdir/system"
erfanrun $romsdir/$sourcever/$romtype/$romtypename/debloat.sh "$systemdir/system"

# Resign to AOSP keys
if [[ ! -e $romsdir/$sourcever/$romtype/$romtypename/DONTRESIGN ]]; then
    if [[ ! -e $romsdir/$sourcever/$romtype/DONTRESIGN ]]; then
        echo "Resigning to AOSP keys"
        python $toolsdir/ROM_resigner/resign.py "$systemdir/system" $toolsdir/ROM_resigner/AOSP_security
        $prebuiltdir/resigned/make.sh "$systemdir/system"
    fi
fi

# Start patching
echo "Patching started..."
erfanrun $scriptsdir/fixsymlinks.sh "$systemdir/system"
erfanrun $scriptsdir/nukeABstuffs.sh "$systemdir/system"
erfanrun $prebuiltdir/common/make.sh "$systemdir/system"
erfanrun $prebuiltdir/$sourcever/make.sh "$systemdir/system"
erfanrun $prebuiltdir/$sourcever/makeroot.sh "$systemdir"
erfanrun $prebuiltdir/vendor_vndk/make$sourcever.sh "$systemdir/system"
erfanrun $romsdir/$sourcever/$romtype/make.sh "$systemdir/system"
erfanrun $romsdir/$sourcever/$romtype/makeroot.sh "$systemdir"
if [ ! "$romtype" == "$romtypename" ]; then
    erfanrun $romsdir/$sourcever/$romtype/$romtypename/make.sh "$systemdir/system"
    erfanrun $romsdir/$sourcever/$romtype/$romtypename/makeroot.sh "$systemdir"
fi
if [ "$outputtype" == "Aonly" ] && [ ! "$romtype" == "$romtypename" ]; then
    erfanrun $romsdir/$sourcever/$romtype/$romtypename/makeA.sh "$systemdir/system"
fi
if [ "$outputtype" == "Aonly" ]; then
    erfanrun $prebuiltdir/$sourcever/makeA.sh "$systemdir/system"
    erfanrun $romsdir/$sourcever/$romtype/makeA.sh "$systemdir/system"
fi

# Fixing environ
if [ "$outputtype" == "Aonly" ]; then
    if [[ ! $(ls "$systemdir/system/etc/init/" | grep *environ*) ]]; then
        echo "Generating environ.rc"
        echo "# AUTOGENERATED FILE BY ERFANGSI TOOLS" > "$systemdir/system/etc/init/init.treble-environ.rc"
        echo "on init" >> "$systemdir/system/etc/init/init.treble-environ.rc"
        cat "$systemdir/init.environ.rc" | grep BOOTCLASSPATH >> "$systemdir/system/etc/init/init.treble-environ.rc"
        cat "$systemdir/init.environ.rc" | grep SYSTEMSERVERCLASSPATH >> "$systemdir/system/etc/init/init.treble-environ.rc"
    fi
fi

if [[ $(grep "ro.build.display.id" $systemdir/system/build.prop) ]]; then
    displayid="ro.build.display.id"
elif [[ $(grep "ro.build.id" $systemdir/system/build.prop) ]]; then
    displayid="ro.build.id"
fi
displayid2=$(echo "$displayid" | sed 's/\./\\./g')
bdisplay=$(grep "$displayid" $systemdir/system/build.prop | sed 's/\./\\./g; s:/:\\/:g; s/\,/\\,/g; s/\ /\\ /g')
sed -i "s/$bdisplay/$displayid2=Built\.with\.ErfanGSI\.Tools/" $systemdir/system/build.prop

if [ "$5" == "" ]; then
    echo "Create out dir"
    outdirname="out"
    outdir="$LOCALDIR/$outdirname"
    mkdir -p "$outdir"
else
    outdir=$5
fi

# Getting system size and add approximately 5% on it just for free space
systemsize=`du -sk $systemdir | awk '{$1*=1024;$1=int($1*1.05);printf $1}'`

date=`date +%Y%m%d`
outputname="$romtypename-$outputtype-$sourcever-$date-ErfanGSI.img"
output="$outdir/$outputname"

echo "Creating Image: $outputname"
# Use ext4fs to make image in P or older!
if [ "$sourcever" -lt "10" ]; then
    useold="--old"
fi
$scriptsdir/mkimage.sh $systemdir $outputtype $systemsize $output $useold

echo "Remove Temp dir"
rm -rf "$tempdir"
