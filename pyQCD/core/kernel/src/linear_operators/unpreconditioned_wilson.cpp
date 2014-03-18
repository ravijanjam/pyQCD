#include <linear_operators/unpreconditioned_wilson.hpp>

UnpreconditionedWilson::UnpreconditionedWilson(
    const double mass, const vector<complex<double> >& boundaryConditions,
    Lattice* lattice) : lattice_(lattice)
{
  // Class constructor - we set the fermion mass, create a pointer to the 
  // lattice and compute the frequently used spin structures used within the
  // Dirac operator.
  this->mass_ = mass;
  this->operatorSize_ 
    = 12 * int(pow(lattice->spatialExtent, 3)) * lattice->temporalExtent;

  for (int i = 0; i < 4; ++i) {
    this->spinStructures_.push_back(Matrix4cd::Identity() - pyQCD::gammas[i]);
  }

  for (int i = 0; i < 4; ++i) {
    this->spinStructures_.push_back(Matrix4cd::Identity() + pyQCD::gammas[i]);
  }
  // Here are some Hermitian gamma matrices to use when computing a Hermitian
  // version of the gamma operator
  for (int i = 0; i < 8; ++i) {
    this->hermitianSpinStructures_.push_back(this->spinStructures_[i] 
					     * pyQCD::gamma5);
  }

  // Initialise tadpole coefficients
  this->tadpoleCoefficients_[0] = lattice->ut();
  this->tadpoleCoefficients_[1] = lattice->us();
  this->tadpoleCoefficients_[2] = lattice->us();
  this->tadpoleCoefficients_[3] = lattice->us();

  this->nearestNeighbours_ = pyQCD::getNeighbourIndices(1, this->lattice_);
  this->boundaryConditions_ = pyQCD::getBoundaryConditions(1, boundaryConditions,
							   this->lattice_);
}



UnpreconditionedWilson::~UnpreconditionedWilson()
{
  // Empty destructor
}



VectorXcd UnpreconditionedWilson::apply(const VectorXcd& psi)
{
  // Right multiply a vector by the operator
  VectorXcd eta = VectorXcd::Zero(this->operatorSize_); // The output vector

  // If psi's the wrong size, get out of here before we segfault
  if (psi.size() != this->operatorSize_)
    return eta;

#pragma omp parallel for
  for (int i = 0; i < this->operatorSize_; ++i) {
    int etaSiteIndex = i / 12; // Site index of the current row in 
    int alpha = (i % 12) / 3; // Spin index of the current row in eta
    int a = i % 3; // Colour index of the current row in eta

    // Now add the mass term
    eta(i) = (1 + 3 / this->lattice_->chi() + this->mass_) * psi(i);

    // Loop over the four gamma indices (mu) in the sum inside the Wilson action
    for (int mu = 0; mu < 4; ++mu) {
      
      // Now we determine the indices of the neighbouring links

      int siteBehindIndex = this->nearestNeighbours_[etaSiteIndex][mu];
      int siteAheadIndex = this->nearestNeighbours_[etaSiteIndex][mu + 4];

      // Now loop over spin and colour indices for the portion of the row we're
      // on

      for (int j = 0; j < 12; ++j) {
	int beta = j / 3; // Compute spin
	int b = j % 3; // Compute colour
	eta(i)
	  -= 0.5 * this->spinStructures_[mu](alpha, beta)
	  * this->boundaryConditions_[etaSiteIndex][mu]
	  * conj(this->lattice_->getLink(4 * siteBehindIndex + mu)(b, a))
	  * psi(12 * siteBehindIndex + 3 * beta + b)
	  / this->tadpoleCoefficients_[mu % 4];
	
	eta(i)
	  -= 0.5 * this->spinStructures_[mu + 4](alpha, beta)
	  * this->boundaryConditions_[etaSiteIndex][mu + 4]
	  * this->lattice_->getLink(4 * etaSiteIndex + mu)(a, b)
	  * psi(12 * siteAheadIndex + 3 * beta + b)
	  / this->tadpoleCoefficients_[mu % 4];
      }
    }
  }

  return eta;
}



VectorXcd UnpreconditionedWilson::applyHermitian(const VectorXcd& psi)
{
  VectorXcd eta = this->apply(psi);

  return pyQCD::multiplyGamma5(eta);
}



VectorXcd UnpreconditionedWilson::undoHermiticity(const VectorXcd& psi)
{
  return pyQCD::multiplyGamma5(psi);
}


