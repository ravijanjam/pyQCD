
CudaLinearOperator::CudaLinearOperator(const int L, const int T,
				       const int precondition,
				       const int hermitian, Complex* links,
				       const bool copyLinks)
  : super(precondition > 0 ? 6 * L * L * L * T : 12 * L * L * L * T,
	  precondition > 0 ? 6 * L * L * L * T : 12 * L * L * L * T)
{
  this->N = 12 * L * L * L * T;
  this->L_ = L;
  this->T_ = T;

  this->precondition_ = precondition;
  this->hermitian_ = hermitian;

  // Number of complex numbers in the array of links
  if (copyLinks) {
    int size = 3 * this->N * sizeof(Complex);
    cudaMalloc((void**) &this->links_, size);
    cudaMemcpy(this->links_, links, size, cudaMemcpyHostToDevice);
  }
  else
    this->links_ = links;
}



CudaLinearOperator::~CudaLinearOperator()
{
  cudaFree(this->links_);
}



void CudaLinearOperator::operator()(const VectorTypeDev& x,
				    VectorTypeDev& y) const
{
  const Complex* x_ptr = thrust::raw_pointer_cast(&x[0]);
  Complex* y_ptr = thrust::raw_pointer_cast(&y[0]);

  if (this->precondition_) {
    if (this->hermitian_)
      this->applyPreconditionedHermitian(y_ptr, x_ptr);
    else
      this->applyPreconditioned(y_ptr, x_ptr);    
  }
  else {
    if (this->hermitian_)
      this->applyHermitian(y_ptr, x_ptr);
    else
      this->apply(y_ptr, x_ptr);
  }
}



void CudaLinearOperator::makeEvenOdd(Complex* y, const Complex* x) const
{
  // Permutes the supplied spinor, shuffling it so the upper half contains
  // the even sites and the lower half contains the odd sites

  int nSites = this->N / 12;

  int* indices = (int*) malloc(nSites / 2 * sizeof(int));
  cudaMemcpy(indices, this->evenIndices_, nSites / 2 * sizeof(int),
	     cudaMemcpyDeviceToHost);

  for (int i = 0; i < nSites / 2; ++i) {
    for (int j = 0; j < 12; ++j)
      y[12 * i + j] = x[12 * indices[i] + j];
  }

  cudaMemcpy(indices, this->oddIndices_, nSites / 2 * sizeof(int),
	     cudaMemcpyDeviceToHost);

  for (int i = nSites / 2; i < nSites; ++i) {
    for (int j = 0; j < 12; ++j)
      y[12 * i + j] = x[12 * indices[i - nSites / 2] + j];
  }

  free(indices);
}



void CudaLinearOperator::removeEvenOdd(Complex* y, const Complex* x) const
{
  // Permutes the supplied spinor, shuffling it so it's back in lexicographic
  // order

  int nSites = this->N / 12;

  int* indices = (int*) malloc(nSites / 2 * sizeof(int));
  cudaMemcpy(indices, this->evenIndices_, nSites / 2 * sizeof(int),
	     cudaMemcpyDeviceToHost);

  for (int i = 0; i < nSites / 2; ++i) {
    for (int j = 0; j < 12; ++j)
      y[12 * indices[i] + j] = x[12 * i + j];
  }

  cudaMemcpy(indices, this->oddIndices_, nSites / 2 * sizeof(int),
	     cudaMemcpyDeviceToHost);

  for (int i = nSites / 2; i < nSites; ++i) {
    for (int j = 0; j < 12; ++j)
      y[12 * indices[i - nSites / 2] + j] = x[12 * i + j];
  }

  free(indices);
}



void CudaLinearOperator::makeEvenOddSource(Complex* y, const Complex* xe,
					   const Complex* xo) const
{
  // Create the source required to do an even-odd inversion. To save GPU
  // memory, we only generate the odd part (the lower half) of the source.
  // Create the source required to do an even-odd inversion. Note that it's
  // assumed here that x is ***already*** even-odd ordered. y is then the
  // lower half of the source, which is all you need for the solve
  int dimGrid;
  int dimBlock;
  setGridAndBlockSize(dimBlock, dimGrid, this->N / 2);

  Complex* z;
  cudaMalloc((void**) &z, this->N / 2 * sizeof(Complex));
  assignDev<<<dimGrid,dimBlock>>>(z, 0.0, this->N / 2);

  this->applyOddEven(z, xe);
  this->applyEvenEvenInv(z, z);

  assignDev<<<dimGrid,dimBlock>>>(y, xo, this->N / 2);

  saxpyDev<<<dimGrid,dimBlock>>>(y, z, -1.0, this->N / 2);

  cudaFree(z);
}



void CudaLinearOperator::makeEvenOddSolution(Complex* y, const Complex* xe,
					     const Complex* xo) const
{
  // Do the inverse of what makeEvenOddSource does. Note that the final
  // y is odd part of the solution (the second half)

  int dimGrid;
  int dimBlock;
  setGridAndBlockSize(dimBlock, dimGrid, this->N / 2);

  Complex* z;
  cudaMalloc((void**) &z, this->N / 2 * sizeof(Complex));
  assignDev<<<dimGrid,dimBlock>>>(z, 0.0, this->N / 2);

  this->applyEvenOdd(z, xo);
  this->applyEvenEvenInv(z, z);
  assignDev<<<dimGrid,dimBlock>>>(y, xe, this->N / 2);

  saxpyDev<<<dimGrid,dimBlock>>>(y, z, -1.0, this->N / 2);

  cudaFree(z);
}
