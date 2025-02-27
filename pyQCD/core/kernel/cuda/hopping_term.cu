
template <int numHops>
CudaHoppingTerm<numHops>::CudaHoppingTerm(const Complex scaling,
					  const int L, const int T,
					  const bool precondition,
					  const bool hermitian,
					  const Complex* boundaryConditions,
					  Complex* links, const bool copyLinks)
  : CudaLinearOperator(L, T, precondition, hermitian, links, copyLinks)
{
  // Constructor - creates Wilson spin structures.

  Complex hostGammas[64];
  createGammas(hostGammas);
  Complex hostSpinStructures[128];
  diagonalSpinMatrices(hostSpinStructures, 1.0);
  diagonalSpinMatrices(hostSpinStructures + 64, 1.0);
  subtractArray(hostSpinStructures, hostGammas, 64);
  addArray(hostSpinStructures + 64, hostGammas, 64);

  this->init(scaling, L, T, precondition, hermitian, boundaryConditions,
	     hostSpinStructures, links, copyLinks);
}



template <int numHops>
CudaHoppingTerm<numHops>::CudaHoppingTerm(const Complex scaling,
					  const int L, const int T,
					  const bool precondition,
					  const bool hermitian,
					  const Complex* boundaryConditions,
					  const Complex* spinStructures,
					  const int spinLength, Complex* links,
					  const bool copyLinks)
  : CudaLinearOperator(L, T, precondition, hermitian, links, copyLinks)
{
  // Constructor - user-specified spin structures

  if (spinLength == 128)
    this->init(scaling, L, T, precondition, hermitian, boundaryConditions,
	       spinStructures, links, copyLinks);
  else {
    Complex hostSpinStructures[128];
    diagonalSpinMatrices(hostSpinStructures, 0.0);
    diagonalSpinMatrices(hostSpinStructures + 64, 0.0);
    for (int i = 0; i < 8; ++i) {
      addArray(hostSpinStructures + 16 * i, spinStructures, 16);
    }
    this->init(scaling, L, T, precondition, hermitian, boundaryConditions,
	       hostSpinStructures, links, copyLinks);
  }
}



template <int numHops>
CudaHoppingTerm<numHops>::~CudaHoppingTerm()
{
  cudaFree(this->spinStructures_);
  cudaFree(this->neighbours_);
  cudaFree(this->evenIndices_);
  cudaFree(this->oddIndices_);
  cudaFree(this->evenNeighbours_);
  cudaFree(this->oddNeighbours_);
  cudaFree(this->boundaryConditions_);
}



template <int numHops>
void CudaHoppingTerm<numHops>::init(const Complex scaling,
				    const int L, const int T,
				    const bool precondition,
				    const bool hermitian,
				    const Complex* boundaryConditions, 
				    const Complex* spinStructures,
				    Complex* links, const bool copyLinks)
{
  // Shared constructor code
  
  int numSites = L * L * L * T;

  this->scaling_ = scaling;
  
  // First copy over the spin structures
  cudaMalloc((void**) &this->spinStructures_, 128 * sizeof(Complex));
  cudaMemcpy(this->spinStructures_, spinStructures, 128 * sizeof(Complex),
	     cudaMemcpyHostToDevice);

  // Generate boundary conditions then copy them over
  int size = 8 * numSites * sizeof(Complex);
  Complex* hostBoundaryConditions = (Complex*) malloc(size);
  generateBoundaryConditions(hostBoundaryConditions, numHops,
			     boundaryConditions, L, T);
  // Do the copy
  cudaMalloc((void**) &this->boundaryConditions_, size);
  cudaMemcpy(this->boundaryConditions_, hostBoundaryConditions, size,
	     cudaMemcpyHostToDevice);
  free(hostBoundaryConditions);

  // Now for the neighbour indices
  size = 8 * numSites * sizeof(int);
  int* hostNeighbours = (int*) malloc(size);
  generateNeighbours(hostNeighbours, numHops, L, T);

  cudaMalloc((void**) &this->neighbours_, size);
  cudaMemcpy(this->neighbours_, hostNeighbours, size,
	     cudaMemcpyHostToDevice);

  int* hostEvenIndices = (int*) malloc(size / 16);
  int* hostOddIndices = (int*) malloc(size / 16);

  int* hostEvenNeighbours = (int*) malloc(size / 2);
  int* hostOddNeighbours = (int*) malloc(size / 2);

  for (int i = 0; i < T; ++i) {
    for (int j = 0; j < L; ++j) {
      for (int k = 0; k < L; ++k) {
	for (int l = 0; l < L; ++l) {
	  int siteIndex = l + L * (k + L * (j + L * i));
	  
	  if ((i + j + k + l) % 2 == 0) {
	    hostEvenIndices[siteIndex / 2] = siteIndex;
	    for (int m = 0; m < 8; ++m)
	      hostEvenNeighbours[8 * (siteIndex / 2) + m]
		= hostNeighbours[8 * siteIndex + m];
	  }
	  else {
	    hostOddIndices[siteIndex / 2] = siteIndex;
	    for (int m = 0; m < 8; ++m)
	      hostOddNeighbours[8 * (siteIndex / 2) + m]
		= hostNeighbours[8 * siteIndex + m];
	  }
	}
      }
    }
  }

  // Now copy all the even and odd indices over
  cudaMalloc((void**) &this->evenIndices_, size / 16);
  cudaMemcpy(this->evenIndices_, hostEvenIndices, size / 16,
	     cudaMemcpyHostToDevice);
  cudaMalloc((void**) &this->oddIndices_, size / 16);
  cudaMemcpy(this->oddIndices_, hostOddIndices, size / 16,
	     cudaMemcpyHostToDevice);
  cudaMalloc((void**) &this->evenNeighbours_, size / 2);
  cudaMemcpy(this->evenNeighbours_, hostEvenNeighbours, size / 2,
	     cudaMemcpyHostToDevice);
  cudaMalloc((void**) &this->oddNeighbours_, size / 2);
  cudaMemcpy(this->oddNeighbours_, hostOddNeighbours, size / 2,
	     cudaMemcpyHostToDevice);

  free(hostNeighbours);
  free(hostEvenIndices);
  free(hostEvenNeighbours);
  free(hostOddIndices);
  free(hostOddNeighbours);
}



template <int numHops>
void CudaHoppingTerm<numHops>::apply3d(Complex* y, const Complex* x) const
{
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N);

  hoppingKernel3d<numHops><<<dimGrid,dimBlock>>>(y, x, this->links_,
						 this->spinStructures_,
						 this->neighbours_,
						 this->boundaryConditions_,
						 this->scaling_,
						 this->L_, this->T_);
}



template <int numHops>
void CudaHoppingTerm<numHops>::apply(Complex* y, const Complex* x) const
{
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N);

  hoppingKernel<numHops><<<dimGrid,dimBlock>>>(y, x, this->links_,
					       this->spinStructures_,
					       this->neighbours_,
					       this->boundaryConditions_,
					       this->scaling_,
					       this->L_, this->T_);  
}



template <int numHops>
void CudaHoppingTerm<numHops>::applyHermitian(Complex* y,
					      const Complex* x) const
{
  this->apply(y, x);
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N);
  applyGamma5<<<dimGrid,dimBlock>>>(y, y, this->L_, this->T_);
}



template <int numHops>
void CudaHoppingTerm<numHops>::makeHermitian(Complex* y, const Complex* x) const
{
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N);
  applyGamma5<<<dimGrid,dimBlock>>>(y, x, this->L_, this->T_);  
}



template <int numHops>
void CudaHoppingTerm<numHops>::applyEvenOdd(Complex* y, const Complex* x) const
{
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N / 2);
  precHoppingKernel<numHops><<<dimGrid,dimBlock>>>(y, x, this->links_,
						   this->spinStructures_,
						   this->evenNeighbours_,
						   this->evenIndices_,
						   this->boundaryConditions_,
						   this->scaling_,
						   this->L_, this->T_);
}



template <int numHops>
void CudaHoppingTerm<numHops>::applyOddEven(Complex* y, const Complex* x) const
{
  int dimBlock;
  int dimGrid;
  setGridAndBlockSize(dimBlock, dimGrid, this->N / 2);
  precHoppingKernel<numHops><<<dimGrid,dimBlock>>>(y, x, this->links_,
						   this->spinStructures_,
						   this->oddNeighbours_,
						   this->oddIndices_,
						   this->boundaryConditions_,
						   this->scaling_,
						   this->L_, this->T_);  
}
