cat $1 > $4
echo "exposed-modules: `cat $2`" >> $4
echo "depends: $(cat $3 | tr '\n' " ")" >> $4
