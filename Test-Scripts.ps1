#.\Make-GroupVPG.ps1 -GroupName 'GROUP00-CHAPDA-T2' `
#                    -MigrationType Mig `
#                    -ZertoSourceServer 'il1zerto.nuveen.com' `
#                    -ZertoUser 'nuveen\e_lewicg'



.\Make-GroupVPG.ps1 -GroupName 'GROUP01-DENPDB' `
                    -MigrationType Mig `
                    -ZertoSourceServer 'il1zerto.nuveen.com' `
                    -ZertoUser 'nuveen\e_lewicg'



### PRE POC
.\Make-GroupVPG.ps1 -GroupName  GROUPPREPOC-CHAPDA     -MigrationType Mig -ZertoSourceServer 'il1zerto.nuveen.com'           -ZertoUser 'nuveen\e_lewicg' #-CommitVPG
.\Make-GroupVPG.ps1 -GroupName  GROUPPREPOC-DR         -MigrationType DR  -ZertoSourceServer 'chapda3zvm01.ad.tiaa-cref.org' -ZertoUser 'nuveen\lewicg'   #-CommitVPG
.\Make-GroupVPG.ps1 -GroupName  GROUPPREPOC-CHAPDA-FP  -MigrationType FP  -ZertoSourceServer 'chapda3zvm01.ad.tiaa-cref.org' -ZertoUser 'nuveen\lewicg'   #-CommitVPG

