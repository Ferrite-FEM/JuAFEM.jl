# Symmetric quadrature rules takes from
#   Witherden, Freddie D., and Peter E. Vincent. "On the identification of 
#   symmetric quadrature rules for finite element methods." Computers & 
#   Mathematics with Applications 69.10 (2015): 1232-1241.
function _get_gauss_pyramiddata_polyquad(n::Int)
  if n == 1
      xw = [0 0  -0.5  2.6666666666666666666666666666666666667]
  elseif n == 2
      xw = [
                                               0                                          0   0.21658207711955775339238838942231815011   0.60287280353093925911579186632475611728
        0.71892105581179616210276971993495767914                                          0  -0.70932703285428855378369530000365161136   0.51594846578393185188771870008547763735
                                               0   0.71892105581179616210276971993495767914  -0.70932703285428855378369530000365161136   0.51594846578393185188771870008547763735
       -0.71892105581179616210276971993495767914                                          0  -0.70932703285428855378369530000365161136   0.51594846578393185188771870008547763735
                                               0  -0.71892105581179616210276971993495767914  -0.70932703285428855378369530000365161136   0.51594846578393185188771870008547763735
      ]
  elseif n == 3
      xw = [
                                              0                                          0   0.14285714077213670617734974746312582074   0.67254902379402809443607078852738472107
                                              0                                          0  -0.99999998864829993678698817507850804299   0.30000001617617323518941867705084375434
       0.56108361105873963414196154191891982155   0.56108361105873963414196154191891982155  -0.66666666666666666666666666666666666667   0.42352940667411633426029430027210954782
       0.56108361105873963414196154191891982155  -0.56108361105873963414196154191891982155  -0.66666666666666666666666666666666666667   0.42352940667411633426029430027210954782
      -0.56108361105873963414196154191891982155   0.56108361105873963414196154191891982155  -0.66666666666666666666666666666666666667   0.42352940667411633426029430027210954782
      -0.56108361105873963414196154191891982155  -0.56108361105873963414196154191891982155  -0.66666666666666666666666666666666666667   0.42352940667411633426029430027210954782
      ]
  elseif n == 4
      xw = [
                                              0                                          0   0.35446557777227471722730849524904581806   0.30331168845504517111391728481208001144
                                              0                                          0  -0.74972609378250711033655604388057044149   0.55168907357213937275730716433358729608
        0.6505815563982325146829577797417295398                                          0  -0.35523170084357268589593075201816127231   0.28353223437153468006819777082540613962
        0    0.6505815563982325146829577797417295398  -0.35523170084357268589593075201816127231   0.28353223437153468006819777082540613962
       -0.6505815563982325146829577797417295398                                          0  -0.35523170084357268589593075201816127231   0.28353223437153468006819777082540613962
                                              0   -0.6505815563982325146829577797417295398  -0.35523170084357268589593075201816127231   0.28353223437153468006819777082540613962
       0.65796699712169008954533549931479427127   0.65796699712169008954533549931479427127  -0.92150343220236930457646242598412224897   0.16938424178833585063066278355484370017
       0.65796699712169008954533549931479427127  -0.65796699712169008954533549931479427127  -0.92150343220236930457646242598412224897   0.16938424178833585063066278355484370017
      -0.65796699712169008954533549931479427127   0.65796699712169008954533549931479427127  -0.92150343220236930457646242598412224897   0.16938424178833585063066278355484370017
      -0.65796699712169008954533549931479427127  -0.65796699712169008954533549931479427127  -0.92150343220236930457646242598412224897   0.16938424178833585063066278355484370017
      ]
  else
      throw(ArgumentError("unsupported order for prism polyquad integration"))
  end
    # Transform from [-1,1] × [-1,1] × [-1,1] pyramid with volume 8/3 and with 5th node in center
    # to pyramid [0,1] × [0,1] × [0,1] with volume 1/3 and with 5th node in corner
    f1 = (x,y,z) -> (0.5(x+1.0), 0.5(y+1.0), 0.5(z+1.0))
    f2 = (x,y,z) -> (2x-z, 2y-z, z)

    for i in axes(xw, 1)
        x,y,z,w = xw[i,:]
        x,y,z = f1(x,y,z)
        x,y,z = f2(x,y,z)

        xw[i, 1] = x
        xw[i, 2] = y
        xw[i, 3] = z
        xw[i, 4] = w * ((1/3)/(8/3))
    end

  return xw
end