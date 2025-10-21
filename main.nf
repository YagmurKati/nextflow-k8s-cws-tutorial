nextflow.enable.dsl=2

process SAY_HELLO {
  debug true
  """
  echo "hello from k8s + cws"
  """
}

workflow {
  SAY_HELLO()
}

