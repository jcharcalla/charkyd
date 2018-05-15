# Schdulerler logic
#
# This is meant to be containerized
#

# Start 3 monitors for this service
#
# Watch for new jobs

# take the job, aka update key. then wait and query the key again to make 
# sure we have it claimed add something like "scheduler:thisnode"

# If no other schduler has claimed it move on

# on new job select nodes from correct rack, reagion, <alt>, node specific.
# choose node to run on

# Run deployment shell `git clone ansible && ansible-playbook ...`

# On success of installing the service, submit the job to node or nodes (maybe
# have monitoring service start the nodes like the previous version)

# If monitoring was requested start them now (need method for custome monitor,
# also, monitors should monitor each other and submit a new job if needed)

# once deployment has been sucseccful delete the entry and add it to a 
# /deployed/region/rack/nodeid location so that we can remove them if needed
# or at least know what was deployed where.
