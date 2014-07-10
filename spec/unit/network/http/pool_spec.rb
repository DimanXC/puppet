#! /usr/bin/env ruby
require 'spec_helper'

require 'puppet/network/http'
require 'puppet/network/http_pool'

describe Puppet::Network::HTTP::Pool do
  before :each do
    Puppet::SSL::Key.indirection.terminus_class = :memory
    Puppet::SSL::CertificateRequest.indirection.terminus_class = :memory
  end

  let(:site) do
    Puppet::Network::HTTP::Site.new('https', 'rubygems.org', 443)
  end

  let(:different_site) do
    Puppet::Network::HTTP::Site.new('https', 'github.com', 443)
  end

  def create_pool
    Puppet::Network::HTTP::Pool.new
  end

  def create_pool_with_connections(site, *connections)
    pool = Puppet::Network::HTTP::Pool.new
    connections.each do |conn|
      pool.release(site, conn)
    end
    pool
  end

  def create_pool_with_expired_connections(site, *connections)
    # setting keepalive timeout to -1 ensures any newly added
    # connections have already expired
    pool = Puppet::Network::HTTP::Pool.new(-1)
    connections.each do |conn|
      pool.release(site, conn)
    end
    pool
  end

  def create_connection(site)
    stub(site.addr, :started? => false, :start => nil, :finish => nil)
  end

  context 'when yielding a connection' do
    it 'yields a connection' do
      conn = create_connection(site)
      pool = create_pool_with_connections(site, conn)
      factory = mock('factory')

      yielded_conn = nil
      pool.with_connection(site, factory) { |c| yielded_conn = c }

      expect(yielded_conn).to eq(conn)
    end

    it 'returns the connection to the pool' do
      conn = create_connection(site)
      pool = create_pool
      pool.release(site, conn)

      factory = mock('factory')
      pool.with_connection(site, factory) do |c|
        expect(pool.pool[site]).to eq([])
      end

      expect(pool.pool[site].first.connection).to eq(conn)
    end

    it 'propagates exceptions' do
      conn = create_connection(site)
      pool = create_pool
      pool.release(site, conn)

      factory = mock('factory')
      expect {
        pool.with_connection(site, factory) do |c|
          raise IOError, 'connection reset'
        end
      }.to raise_error(IOError, 'connection reset')
    end

    it 'closes the yielded connection when an error occurs' do
      # we're not distinguishing between network errors that would
      # suggest we close the socket, and other errors

      conn = create_connection(site)
      pool = create_pool
      pool.release(site, conn)

      pool.expects(:release).with(site, conn).never

      factory = mock('factory')
      pool.with_connection(site, factory) do |c|
        raise IOError, 'connection reset'
      end rescue nil

      expect(pool.pool[site]).to eq([])
    end
  end

  context 'when borrowing' do
    it 'returns a new connection if the pool is empty' do
      conn = create_connection(site)
      factory = mock('factory')
      factory.expects(:create_connection).with(site).returns(conn)

      pool = create_pool
      expect(pool.borrow(site, factory)).to eq(conn)
    end

    it 'returns a matching connection' do
      conn = create_connection(site)
      pool = create_pool_with_connections(site, conn)

      factory = mock('factory')
      factory.expects(:create_connection).never

      expect(pool.borrow(site, factory)).to eq(conn)
    end

    it 'returns a new connection if there are no matching sites' do
      different_conn = create_connection(different_site)
      pool = create_pool_with_connections(different_site, different_conn)

      conn = create_connection(site)
      factory = mock('factory')
      factory.expects(:create_connection).with(site).returns(conn)

      expect(pool.borrow(site, factory)).to eq(conn)
    end

    it 'returns started connections' do
      conn = create_connection(site)
      conn.expects(:start)

      factory = stub('factory', :create_connection => conn)

      pool = create_pool
      expect(pool.borrow(site, factory)).to eq(conn)
    end

    it "doesn't start a cached connection" do
      conn = create_connection(site)
      conn.expects(:start).never

      pool = create_pool_with_connections(site, conn)
      pool.borrow(site, stub('factory'))
    end

    it 'returns the most recently used connection from the pool' do
      least_recently_used = create_connection(site)
      most_recently_used = create_connection(site)

      pool = create_pool_with_connections(site, least_recently_used, most_recently_used)
      expect(pool.borrow(site, stub('factory'))).to eq(most_recently_used)
    end

    it 'finishes expired connections' do
      conn = create_connection(site)
      conn.expects(:finish)

      pool = create_pool_with_expired_connections(site, conn)
      pool.borrow(site, stub('factory', :create_connection => stub('conn', :start => nil)))
    end

    it 'logs an exception if it fails to close an expired connection' do
      Puppet.expects(:log_exception).with(is_a(IOError), "Failed to close connection for #{site}: read timeout")

      conn = create_connection(site)
      conn.expects(:finish).raises(IOError, 'read timeout')

      pool = create_pool_with_expired_connections(site, conn)
      pool.borrow(site, stub('factory', :create_connection => stub('open_conn', :start => nil)))
    end
  end

  context 'when releasing a connection' do
    it 'adds the connection to an empty pool' do
      conn = create_connection(site)

      pool = create_pool
      pool.release(site, conn)

      expect(pool.pool[site].first.connection).to eq(conn)
    end

    it 'adds the connection to a pool with a connection for the same site' do
      pool = create_pool
      pool.release(site, create_connection(site))
      pool.release(site, create_connection(site))

      expect(pool.pool[site].count).to eq(2)
    end

    it 'adds the connection to a pool with a connection for a different site' do
      pool = create_pool
      pool.release(site, create_connection(site))
      pool.release(different_site, create_connection(different_site))

      expect(pool.pool[site].count).to eq(1)
      expect(pool.pool[different_site].count).to eq(1)
    end

    it 'should ignore expired connections' do
      pending("No way to know if client is releasing an expired connection")
    end
  end

  context 'when closing' do
    it 'clears the pool' do
      pool = create_pool
      pool.close

      expect(pool.pool).to be_empty
    end

    it 'closes all cached connections' do
      conn = create_connection(site)
      conn.expects(:finish)

      factory = stub('factory', :create_connection => conn)

      pool = create_pool_with_connections(site, conn)
      pool.with_connection(site, factory) { |c| }

      pool.close
    end
  end
end
